import UIKit
import WebKit

public protocol SessionDelegate: class {
    func session(_ session: Session, didProposeVisitToURL: URL, withAction action: Action)
    func session(_ session: Session, didFailRequestForVisitable visitable: Visitable, withError error: NSError)
    func session(_ session: Session, isLocalURL: URL) -> Bool
    func session(_ session: Session, preProcessingForURL: URL) -> Bool
    func session(_ session: Session, postProcessingForResponse: WKNavigationResponse) -> Bool
    
    func sessionOpenExternal(_ session: Session, url: URL)
    func sessionUpdate(_ session: Session, url: URL)
    func sessionRedirectTo(_ session: Session, url: URL)
    func sessionDidLoadWebView(_ session: Session)
    func sessionDidStartRequest(_ session: Session)
    func sessionDidFinishRequest(_ session: Session)
}

public extension SessionDelegate {
    func sessionDidLoadWebView(_ session: Session) {
        session.webView.navigationDelegate = session
    }

    func session(_ session: Session, openExternalURL url: Foundation.URL) {
        UIApplication.shared.openURL(url)
    }

    func sessionDidStartRequest(_ session: Session) {
    }

    func sessionDidFinishRequest(_ session: Session) {
    }
    
    func session(_ session: Session, isLocalURL: URL) -> Bool {
        return false
    }

    func session(_ session: Session, preProcessingForURL: URL) -> Bool {
        print("default url preprocessing...")
        return false // default behavior: always continue with pre processing
    }
    
    func session(_ session: Session, postProcessingForResponse: WKNavigationResponse) -> Bool {
        print("default url postprocessing...")
        return false // default behavior: always continue with post processing
    }
}

open class Session: NSObject {
    open weak var delegate: SessionDelegate?

    open var webView: WebView {
        return _webView
    }

    fileprivate var _webView: WebView
    fileprivate var initialized = false
    fileprivate var refreshing = false
    fileprivate var coldBootOnNextRequest = false

    public init(webViewConfiguration: WKWebViewConfiguration) {
        _webView = WebView(configuration: webViewConfiguration)
        super.init()
        _webView.delegate = self
    }

    public convenience override init() {
        self.init(webViewConfiguration: WKWebViewConfiguration())
    }

    // MARK: Visiting

    fileprivate var currentVisit: Visit?
    fileprivate var topmostVisit: Visit?

    open var currentVisitIdentifier: String {
        return currentVisit?.visitIdentifier() ?? ""
    }
    
    open var topmostVisitable: Visitable? {
        return topmostVisit?.visitable
    }
    open var topmostVisitIdentifier: String {
        return topmostVisit?.visitIdentifier() ?? ""
    }
    
    open func resetToColdBoot() {
        coldBootOnNextRequest = true
    }

    open func updateCurrentVisitable() {
        // if page was loaded by a submit request, don't update before reload
        if ((webView.url != nil) && (currentVisit != nil) && (currentVisit?.visitable.isWebViewVisitable == true) &&
            (currentVisit?.location != webView.url) && !webView.isSubmitRequest) {
            currentVisit?.location = webView.url!
            currentVisit?.delegate?.visitUpdateURL(webView.url!)
        }
    }
    
    open func visit(_ visitable: Visitable) {
        visitVisitable(visitable, action: .Advance)
    }

    fileprivate func visitVisitable(_ visitable: Visitable, action: Action) {
        guard visitable.visitableURL != nil else { return }

        visitable.visitableDelegate = self

        let visit: Visit

        if visitable.isWebViewVisitable {
            var customReferer: String? = nil
            if let topVisitable = topmostVisit,
               topmostVisitable?.isWebViewVisitable == false {
                customReferer = topVisitable.location.absoluteString
            }
            
            if initialized && !visitable.withColdBoot && !coldBootOnNextRequest && (customReferer == nil) {
                visit = JavaScriptVisit(visitable: visitable, action: action, webView: _webView)
                visit.restorationIdentifier = restorationIdentifierForVisitable(visitable)
            } else {
                visit = ColdBootVisit(visitable: visitable, action: action, webView: _webView)
                visit.referer = customReferer
            }
        } else {
            visit = Visit(visitable: visitable, action: action, webView: _webView)
        }
        
        // update a changed URL before new visit is executed
        if (action == Action.Advance) {
            updateCurrentVisitable()
        }
        currentVisit?.cancel()
        currentVisit = visit

        visit.delegate = self
        visit.start()
    }

    open func reload() {
        if let visitable = topmostVisitable {
            // update a changed URL before reload is executed
            updateCurrentVisitable()
            initialized = false
            visit(visitable)
            topmostVisit = currentVisit
        }
    }

    // MARK: Visitable activation

    fileprivate var activatedVisitable: Visitable?
    open var interactiveTransition: Bool = false

    open func activateVisitable(_ visitable: Visitable) {
        if visitable !== activatedVisitable {
            if let activatedVisitable = self.activatedVisitable {
                deactivateVisitable(activatedVisitable, showScreenshot: true)
            }

            visitable.activateVisitableWebView(webView)
            activatedVisitable = visitable
        }
    }

    open func deactivateVisitable(_ visitable: Visitable, showScreenshot: Bool = false) {
        if visitable === activatedVisitable {
            if showScreenshot {
                visitable.updateVisitableScreenshot()
                visitable.showVisitableScreenshot()
            }

            visitable.deactivateVisitableWebView()
            activatedVisitable = nil
        }
    }

    // MARK: Visitable restoration identifiers

    fileprivate var visitableRestorationIdentifiers = NSMapTable<UIViewController, NSString>(keyOptions: NSPointerFunctions.Options.weakMemory, valueOptions: [])

    fileprivate func restorationIdentifierForVisitable(_ visitable: Visitable) -> String? {
        return visitableRestorationIdentifiers.object(forKey: visitable.visitableViewController) as String?
    }

    fileprivate func storeRestorationIdentifier(_ restorationIdentifier: String, forVisitable visitable: Visitable) {
        visitableRestorationIdentifiers.setObject(restorationIdentifier as NSString, forKey: visitable.visitableViewController)
    }

    fileprivate func completeNavigationForCurrentVisit() {
        if let visit = currentVisit {
            topmostVisit = visit
            visit.completeNavigation()
        }
    }
}

extension Session: VisitDelegate {
    
    func visitRequestDidStart(_ visit: Visit) {
        delegate?.sessionDidStartRequest(self)
    }

    func visitRequestDidFinish(_ visit: Visit) {
        delegate?.sessionDidFinishRequest(self)
    }

    func visitDidFinishWithPreprocessing(_ visit: Visit) {
        //visitRequestDidFinish(visit) - request was not executed
        visitDidFinish(visit)
        //visitDidRender(visit) - page was not rendered
    }
    
    func visit(_ visit: Visit, requestDidFailWithError error: NSError) {
        delegate?.session(self, didFailRequestForVisitable: visit.visitable, withError: error)
    }

    func visitDidInitializeWebView(_ visit: Visit) {
        initialized = true
        delegate?.sessionDidLoadWebView(self)
    }

    func visitWillStart(_ visit: Visit) {
        visit.visitable.showVisitableScreenshot()
        activateVisitable(visit.visitable)
    }

    func visitDidStart(_ visit: Visit) {
        if !visit.hasCachedSnapshot {
            visit.visitable.showVisitableActivityIndicator()
        }
    }

    func visitWillLoadResponse(_ visit: Visit) {
        visit.visitable.updateVisitableScreenshot()
        visit.visitable.showVisitableScreenshot()
    }

    func visitDidRender(_ visit: Visit) {
        visit.visitable.hideVisitableScreenshot()
        visit.visitable.hideVisitableActivityIndicator()
        visit.visitable.visitableDidRender()
    }

    func visitDidComplete(_ visit: Visit) {
        if let restorationIdentifier = visit.restorationIdentifier {
            storeRestorationIdentifier(restorationIdentifier, forVisitable: visit.visitable)
        }
    }

    func visitDidFail(_ visit: Visit) {
        visit.visitable.clearVisitableScreenshot()
        visit.visitable.showVisitableScreenshot()
    }

    func visitDidFinish(_ visit: Visit) {
        coldBootOnNextRequest = false
        if refreshing {
            refreshing = false
            visit.visitable.visitableDidRefresh()
        }
    }
    
    func visitDidRedirect(_ to: URL) {
        delegate?.sessionRedirectTo(self, url: to)
    }
    
    func visitUpdateURL(_ url: URL) {
        delegate?.sessionUpdate(self, url: url)
    }
    
    func performPreprocessing(_ visit: Visit?, URL: URL?) -> Bool {
        if let delegate = self.delegate, let url = URL, let visit = visit {
            if delegate.session(self, preProcessingForURL: url) {
                self.visitDidFinishWithPreprocessing(visit)
                return true;
            }
        }
        return false;
    }
    
    func performPostprocessing(_ navigationResponse: WKNavigationResponse) -> Bool {
        if let delegate = self.delegate {
            return delegate.session(self, postProcessingForResponse: navigationResponse)
        }
        return false
    }
}

extension Session: VisitableDelegate {
    public func visitableViewWillAppear(_ visitable: Visitable) {
		if self.interactiveTransition { return }
		
        guard let topmostVisit = self.topmostVisit, let currentVisit = self.currentVisit else { return }

        if visitable === topmostVisit.visitable && visitable.visitableViewController.isMovingToParent {
            // Back swipe gesture canceled
            if topmostVisit.state == .completed {
                currentVisit.cancel()
            } else {
                visitVisitable(visitable, action: .Advance)
            }
        } else if visitable === currentVisit.visitable && currentVisit.state == .started {
            // Navigating forward - complete navigation early
            completeNavigationForCurrentVisit()
        } else if visitable !== topmostVisit.visitable {
            // Navigating backward
            visitVisitable(visitable, action: .Restore)
        }
    }

    public func visitableViewDidAppear(_ visitable: Visitable) {
        if self.interactiveTransition { return }

        if let currentVisit = self.currentVisit , visitable === currentVisit.visitable {
            // Appearing after successful navigation
            completeNavigationForCurrentVisit()
            if currentVisit.state != .failed {
                activateVisitable(visitable)
            }
        } else if let topmostVisit = self.topmostVisit , visitable === topmostVisit.visitable && topmostVisit.state == .completed {
            // Reappearing after canceled navigation
            visitable.hideVisitableScreenshot()
            visitable.hideVisitableActivityIndicator()
            activateVisitable(visitable)
        }
    }

    public func visitableDidRequestReload(_ visitable: Visitable) {
        if visitable === topmostVisitable {
            reload()
        }
    }

    public func visitableDidRequestRefresh(_ visitable: Visitable) {
        if visitable === topmostVisitable {
            refreshing = true
            visitable.visitableWillRefresh()
            reload()
        }
    }
}

extension Session: WebViewDelegate {
    public func webView(_ webView: WebView, didProposeVisitToLocation location: URL, withAction action: Action) {
        if !(performPreprocessing(currentVisit, URL: location)) {
            delegate?.session(self, didProposeVisitToURL: location, withAction: action)
        }
    }

    public func webViewDidInvalidatePage(_ webView: WebView) {
        if let visitable = topmostVisitable {
            visitable.updateVisitableScreenshot()
            visitable.showVisitableScreenshot()
            visitable.showVisitableActivityIndicator()
            reload()
        }
    }

    public func webView(_ webView: WebView, didFailJavaScriptEvaluationWithError error: NSError) {
        if let currentVisit = self.currentVisit , initialized {
            initialized = false
            currentVisit.cancel()
            visit(currentVisit.visitable)
        }
    }
}

extension Session: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> ()) {
        let navigationDecision = NavigationDecision(navigationAction: navigationAction)
        let isSubmitRequest = (navigationAction.navigationType == .formSubmitted || navigationAction.navigationType == .formResubmitted)
        
        if let webView = webView as? WebView {
            webView.isSubmitRequest = isSubmitRequest
        }

        if isSubmitRequest {
            decisionHandler(.allow)
        } else {
            let processingURL = (navigationAction.navigationType == .linkActivated || navigationDecision.isMainFrameNavigation) ? navigationAction.request.url : nil
            if performPreprocessing(currentVisit, URL: processingURL) {
                decisionHandler(.cancel)
            } else {
                let URL = navigationDecision.externallyOpenableURL
                if let url = URL, (delegate?.session(self, isLocalURL: url) == true) {
                    decisionHandler(.allow)
                    delegate?.session(self, didProposeVisitToURL: url, withAction: Action.Advance)
                } else {
                    decisionHandler(navigationDecision.policy)
                    if let url = URL {
                        openExternalURL(url)
                    } else if navigationDecision.shouldReloadPage {
                        reload()
                    }
                }
            }
        }
    }

    fileprivate struct NavigationDecision {
        let navigationAction: WKNavigationAction

        var policy: WKNavigationActionPolicy {
            return navigationAction.navigationType == .linkActivated || isMainFrameNavigation ? .cancel : .allow
        }

        var externallyOpenableURL: URL? {
            if let URL = navigationAction.request.url , shouldOpenURLExternally {
                return URL
            } else {
                return nil
            }
        }

        var shouldOpenURLExternally: Bool {
            let type = navigationAction.navigationType
            return type == .linkActivated || (isMainFrameNavigation && type == .other)
        }

        var shouldReloadPage: Bool {
            let type = navigationAction.navigationType
            return isMainFrameNavigation && type == .reload
        }

        var isMainFrameNavigation: Bool {
            return navigationAction.targetFrame?.isMainFrame ?? false
        }
    }

    fileprivate func openExternalURL(_ url: Foundation.URL) {
        delegate?.sessionOpenExternal(self, url: url)
    }
}
