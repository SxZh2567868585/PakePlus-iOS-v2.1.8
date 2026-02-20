//
//  WebView.swift
//  PakePlus
//
//  Created by Song on 2025/3/30.
//

import SwiftUI
import WebKit
import AVFoundation

struct WebView: UIViewRepresentable {
    // wkwebview url
    let webUrl: URL
    // is debug
    let debug: Bool
    // userAgent
    let userAgent = Bundle.main.object(forInfoDictionaryKey: "USERAGENT") as? String ?? ""

    func makeUIView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webConfiguration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        webConfiguration.allowsInlineMediaPlayback = true
        webConfiguration.allowsPictureInPictureMediaPlayback = true
        // enable developer extras
        if #available(iOS 16.4, *) {
            webConfiguration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        } else {
            webConfiguration.preferences.setValue(true, forKey: "developerExtrasEnabled")
            UserDefaults.standard.set(true, forKey: "WebKitDeveloperExtras")
        }
        // creat wkwebview
        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        // JS bridge: blob 下载
        webView.configuration.userContentController.add(context.coordinator, name: "blobDownload")

        // debug script
        if debug, let debugScript = WebView.loadJSFile(named: "vConsole") {
            let fullScript = debugScript + "\nvar vConsole = new window.VConsole();"
            let userScript = WKUserScript(
                source: fullScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(userScript)
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }
        }
        // config userAgent
        if !userAgent.isEmpty {
            webView.customUserAgent = userAgent
        }

        // disable double tap zoom
        let script = """
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            document.head.appendChild(meta);
        """
        let scriptInjection = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(scriptInjection)

        // load custom script
        if let customScript = WebView.loadJSFile(named: "custom") {
            let userScript = WKUserScript(
                source: customScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(userScript)
        }

        if webUrl.host?.contains("pakeplus.com") == true {
            // load html file
            if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        } else {
            // load url
            webView.load(URLRequest(url: webUrl))
        }

        // delegate 设置

        // Add gesture recognizers
        let rightSwipeGesture = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRightSwipe(_:)))
        rightSwipeGesture.direction = .right
        webView.addGestureRecognizer(rightSwipeGesture)

        let leftSwipeGesture = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLeftSwipe(_:)))
        leftSwipeGesture.direction = .left
        webView.addGestureRecognizer(leftSwipeGesture)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // add coordinator to prevent zoom
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

// swifui coordinator
class Coordinator: NSObject, UIScrollViewDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private struct BlobDownloadState {
        var filename: String
        var mimeType: String
        var totalChunks: Int
        var receivedChunkIndexes: Set<Int>
        var buffer: Data
    }

    private var blobDownloads: [String: BlobDownloadState] = [:]

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        // disable zoom
        return nil
    }

    // Handle right swipe gesture
    @objc func handleRightSwipe(_ gesture: UISwipeGestureRecognizer) {
        if let webView = gesture.view as? WKWebView, webView.canGoBack {
            webView.goBack()
        }
    }

    // Handle left swipe gesture
    @objc func handleLeftSwipe(_ gesture: UISwipeGestureRecognizer) {
        if let webView = gesture.view as? WKWebView, webView.canGoForward {
            webView.goForward()
        }
    }

    // MARK: - WKNavigationDelegate

    // 拦截导航，识别常见文件类型并触发下载
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // 仅对用户点击链接触发下载，其它导航正常加载
        if navigationAction.navigationType == .linkActivated, shouldDownload(url: url) {
            decisionHandler(.cancel)
            downloadFile(from: url)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("didFinish navigation: \(String(describing: webView.url))")
        // currentURL = webView.url
    }

    // MARK: - 媒体（摄像头 / 麦克风）权限

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // 如果 APP 已经拿到系统层的摄像头/麦克风权限，则直接为网页授权，不再弹出网页权限弹窗
        if hasAppMediaPermission(for: type) {
            decisionHandler(.grant)
        } else {
            // APP 还没有对应权限时，保持默认行为（由系统决定是否弹框）
            decisionHandler(.prompt)
        }
    }

    /// 判断 APP 是否已经拥有对应的系统媒体权限
    private func hasAppMediaPermission(for type: WKMediaCaptureType) -> Bool {
        let videoAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let audioAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        switch type {
        case .camera:
            return videoAuthorized
        case .microphone:
            return audioAuthorized
        case .cameraAndMicrophone:
            return videoAuthorized && audioAuthorized
        @unknown default:
            return false
        }
    }

    // MARK: - WKScriptMessageHandler（blob 下载桥接）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "blobDownload" else { return }
        guard let body = message.body as? [String: Any] else { return }

        let action = (body["action"] as? String) ?? ""
        let id = (body["id"] as? String) ?? ""
        if id.isEmpty { return }

        switch action {
        case "start":
            let filename = sanitizeFilename((body["filename"] as? String) ?? "download")
            let mimeType = (body["mimeType"] as? String) ?? ""
            let totalChunks = max(1, (body["totalChunks"] as? Int) ?? 1)
            blobDownloads[id] = BlobDownloadState(
                filename: filename,
                mimeType: mimeType,
                totalChunks: totalChunks,
                receivedChunkIndexes: [],
                buffer: Data()
            )
            showDownloadStartedHint()

        case "chunk":
            guard var state = blobDownloads[id] else { return }
            guard let index = body["index"] as? Int else { return }
            guard let base64 = body["data"] as? String else { return }

            // 防止重复 chunk
            if state.receivedChunkIndexes.contains(index) { return }
            guard let chunkData = Data(base64Encoded: base64) else { return }

            state.buffer.append(chunkData)
            state.receivedChunkIndexes.insert(index)
            blobDownloads[id] = state

        case "finish":
            guard let state = blobDownloads[id] else { return }
            blobDownloads.removeValue(forKey: id)

            // 只有收齐了才落盘
            guard state.receivedChunkIndexes.count >= state.totalChunks else { return }
            saveAndShareBlobData(state.buffer, filename: state.filename)

        case "error":
            blobDownloads.removeValue(forKey: id)
            if let msg = body["message"] as? String, !msg.isEmpty {
                print("blob 下载失败: \(msg)")
            }

        default:
            return
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "download" }
        // 去掉路径分隔符，避免写文件异常
        return trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func saveAndShareBlobData(_ data: Data, filename: String) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent(filename)

        try? fileManager.removeItem(at: destinationURL)
        do {
            try data.write(to: destinationURL, options: [.atomic])
        } catch {
            print("保存 blob 文件失败: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.presentShareSheet(for: destinationURL)
        }
    }


    /// 判断 URL 是否是需要下载的常见文件类型
    private func shouldDownload(url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension.isEmpty {
            return false
        }

        let downloadableExtensions: Set<String> = [
            // 图片
            "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic",
            // 视频
            "mp4", "mov", "m4v", "avi", "mkv",
            // 音频
            "mp3", "wav", "aac", "m4a", "flac",
            // 文本/文档
            "txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            // 压缩
            "zip", "rar", "7z"
        ]

        return downloadableExtensions.contains(pathExtension)
    }

    /// 使用 URLSession 下载文件并弹出系统分享面板，让用户保存到「文件」或其他 App
    private func downloadFile(from url: URL) {
        print("开始下载文件: \(url.absoluteString)")
        showDownloadStartedHint()
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            if let error = error {
                print("下载失败: \(error.localizedDescription)")
                return
            }

            guard let tempURL = tempURL else {
                print("下载失败: 临时文件不存在")
                return
            }

            // 从响应或 URL 中获取文件名
            let suggestedName = (response as? HTTPURLResponse)?
                .allHeaderFields["Content-Disposition"] as? String

            let fileName: String
            if let suggestedName,
               let range = suggestedName.range(of: "filename=") {
                let namePart = String(suggestedName[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
                fileName = namePart.isEmpty ? url.lastPathComponent : namePart
            } else {
                fileName = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
            }

            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory
            let destinationURL = tempDir.appendingPathComponent(fileName)

            // 若已存在同名文件，先删除
            try? fileManager.removeItem(at: destinationURL)

            do {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            } catch {
                print("移动下载文件失败: \(error.localizedDescription)")
                return
            }

            print("下载完成，临时保存路径: \(destinationURL.path)")

            DispatchQueue.main.async {
                self?.presentShareSheet(for: destinationURL)
            }
        }

        task.resume()
    }

    /// 显示「开始下载」提示（约 2 秒后自动消失）
    private func showDownloadStartedHint() {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) else { return }

            let label = UILabel()
            label.text = "开始下载..."
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .white
            label.backgroundColor = .systemBlue
            label.textAlignment = .center
            label.layer.cornerRadius = 8
            label.clipsToBounds = true
            label.alpha = 0

            let padding: CGFloat = 16
            let topMargin: CGFloat = 20
            label.sizeToFit()
            label.frame.size.width += padding * 2
            label.frame.size.height += padding
            let yCenter = window.safeAreaInsets.top + label.frame.height / 2 + topMargin
            label.center = CGPoint(x: window.bounds.midX, y: yCenter)

            window.addSubview(label)

            UIView.animate(withDuration: 0.25, animations: { label.alpha = 1 })
            UIView.animate(withDuration: 0.25, delay: 1.75, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    /// 弹出系统分享面板，用户可选择保存到「文件」或分享到其它 App
    private func presentShareSheet(for fileURL: URL) {
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = UIApplication.shared.windows.first { $0.isKeyWindow }

        if let topVC = Coordinator.topViewController() {
            topVC.present(activityVC, animated: true, completion: nil)
        } else {
            print("无法找到顶层视图控制器，无法展示分享面板")
        }
    }

    /// 获取当前顶层 UIViewController
    private static func topViewController(base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?.rootViewController) -> UIViewController? {

        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}

extension WebView {
    // load js file from bundle
    static func loadJSFile(named filename: String) -> String? {
        guard let path = Bundle.main.path(forResource: filename, ofType: "js") else {
            print("Could not find \(filename).js in bundle")
            return nil
        }

        do {
            let jsString = try String(contentsOfFile: path, encoding: .utf8)
            return jsString
        } catch {
            print("Error loading \(filename).js: \(error)")
            return nil
        }
    }
}
