//
//  MainWindowController.swift
//  Managed Software Center
//
//  Created by Greg Neagle on 6/29/18.
//  Copyright © 2018 The Munki Project. All rights reserved.
//

import Cocoa
import WebKit

class MainWindowController: NSWindowController, NSWindowDelegate, WebPolicyDelegate, WebResourceLoadDelegate, WebFrameLoadDelegate, WebUIDelegate {

    var _alertedUserToOutstandingUpdates = false
    var _update_in_progress = false
    var managedsoftwareupdate_task = ""
    var cached_self_service = SelfService()
    var alert_controller = MSCAlertController()
    var htmlDir = ""
    
    // status properties
    var _status_title = ""
    var stop_requested = false
    var user_warned_about_extra_updates = false
    
    // Cocoa UI binding properties
    @IBOutlet weak var softwareToolbarButton: MSCToolbarButton!
    @IBOutlet weak var categoriesToolbarButton: MSCToolbarButton!
    @IBOutlet weak var myItemsToolbarButton: MSCToolbarButton!
    @IBOutlet weak var updatesToolbarButton: MSCToolbarButton!
    
    @IBOutlet weak var updateButtonCell: MSCToolbarButtonCell!
    
    @IBOutlet weak var navigateBackButton: NSButton!
    @IBOutlet weak var navigateForwardButton: NSButton!
    @IBOutlet weak var progressSpinner: NSProgressIndicator!
    
    @IBOutlet weak var searchField: NSSearchField!
    
    @IBOutlet weak var webView: WebView!
    
    @IBOutlet weak var softwareMenuItem: NSMenuItem!
    @IBOutlet weak var categoriesMenuItem: NSMenuItem!
    @IBOutlet weak var myItemsMenuItem: NSMenuItem!
    @IBOutlet weak var updatesMenuItem: NSMenuItem!
    @IBOutlet weak var findMenuItem: NSMenuItem!
    
    override func windowDidLoad() {
        super.windowDidLoad()
    
        // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    }
    
    func appShouldTerminate() -> NSApplication.TerminateReply {
        // called by app delegate
        // when it receives applicationShouldTerminate:
        if getUpdateCount() == 0 {
            // no pending updates
            return .terminateNow
        }
        if (currentPageIsUpdatesPage() && !thereAreUpdatesToBeForcedSoon()) {
            // We're already at the updates view, so user is aware of the
            // pending updates, so OK to just terminate
            // (unless there are some updates to be forced soon)
            return .terminateNow
        }
        if (currentPageIsUpdatesPage() && _alertedUserToOutstandingUpdates) {
            return .terminateNow
        }
        // we have pending updates and we have not yet warned the user
        // about them
        alertToPendingUpdates()
        return .terminateCancel
    }
    
    func currentPageIsUpdatesPage() -> Bool {
        // return true if current tab selected is Updates
        return updatesToolbarButton.state == .on
    }
    
    func alertToPendingUpdates() {
        // Alert user to pending updates before quitting the application
        _alertedUserToOutstandingUpdates = true
        // show the updates
        loadUpdatesPage(self)
        var alertTitle = ""
        var alertDetail = ""
        if thereAreUpdatesToBeForcedSoon() {
            alertTitle = NSLocalizedString("Mandatory Updates Pending",
                                           comment: "Mandatory Updates Pending text")
            if let deadline = earliestForceInstallDate() {
                let time_til_logout = deadline.timeIntervalSinceNow
                if time_til_logout > 0 {
                    let deadline_str = stringFromDate(deadline)
                    let formatString = NSLocalizedString(
                        ("One or more updates must be installed by %s. A logout " +
                          "may be forced if you wait too long to update."),
                        comment: "Mandatory Updates Pending detail")
                    alertDetail = String(format: formatString, deadline_str)
                } else {
                    alertDetail = NSLocalizedString(
                        ("One or more mandatory updates are overdue for " +
                         "installation. A logout will be forced soon."),
                        comment: "Mandatory Updates Imminent detail")
                }
            }
        } else {
            alertTitle = NSLocalizedString(
                "Pending updates", comment: "Pending Updates alert title")
            alertDetail = NSLocalizedString(
                "There are pending updates for this computer.",
                comment: "Pending Updates alert detail text")
        }
        let alert = NSAlert()
        alert.messageText = alertTitle
        alert.informativeText = alertDetail
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: "Quit button title"))
        alert.addButton(withTitle: NSLocalizedString("Update now", comment: "Update Now button title"))
        alert.beginSheetModal(for: self.window!, completionHandler: { (modalResponse) -> Void in
            if modalResponse == .alertFirstButtonReturn {
                msc_log("user", "quit")
                NSApp.terminate(self)
            } else if modalResponse == .alertSecondButtonReturn {
                msc_log("user", "install_now_clicked")
                // make sure this alert panel is gone before we proceed
                // which might involve opening another alert sheet
                alert.window.orderOut(self)
                // initiate the updates
                self.updateNow()
                self.loadUpdatesPage(self)
            }
        })
    }
    
    func loadInitialView() {
        // Called by app delegate from applicationDidFinishLaunching:
        enableOrDisableSoftwareViewControls()
        let optional_items = getOptionalInstallItems()
        if optional_items.isEmpty || getUpdateCount() > 0 || !getProblemItems().isEmpty {
            loadUpdatesPage(self)
        } else {
            loadAllSoftwarePage(self)
        }
        displayUpdateCount()
        cached_self_service = SelfService()
    }
    
    func highlightToolbarButtons(_ nameToHighlight: String) {
        softwareToolbarButton.state = (nameToHighlight == "Software" ? .on : .off)
        categoriesToolbarButton.state = (nameToHighlight == "Categories" ? .on : .off)
        myItemsToolbarButton.state = (nameToHighlight == "My Items" ? .on : .off)
        updatesToolbarButton.state = (nameToHighlight == "Updates" ? .on : .off)
    }
    
    func enableOrDisableToolbarButtons(_ enabled: Bool) {
        // Enable or disable buttons in our toolbar
        var enabled_state = enabled
        var updates_button_state = true
        if let window = self.window {
            if window.isMainWindow == false {
                enabled_state = false
                updates_button_state = false
            }
        }
        softwareToolbarButton.isEnabled = enabled_state
        categoriesToolbarButton.isEnabled = enabled_state
        myItemsToolbarButton.isEnabled = enabled_state
        updatesToolbarButton.isEnabled = updates_button_state
    }
    
    func enableOrDisableSoftwareViewControls() {
        // Disable or enable the controls that let us view optional items
        let enabled_state = (getOptionalInstallItems().count > 0)
        enableOrDisableToolbarButtons(enabled_state)
        searchField.isEnabled = enabled_state
        findMenuItem.isEnabled = enabled_state
        softwareMenuItem.isEnabled = enabled_state
        softwareMenuItem.isEnabled = enabled_state
        categoriesMenuItem.isEnabled = enabled_state
        myItemsMenuItem.isEnabled = enabled_state
    }
    
    func munkiStatusSessionEnded(_ sessionResult: Int) {
        // Called by StatusController when a Munki session ends
        msc_debug_log("MunkiStatus session ended: \(sessionResult)")
        msc_debug_log("MunkiStatus session type: \(managedsoftwareupdate_task)")
        let tasktype = managedsoftwareupdate_task
        managedsoftwareupdate_task = ""
        _update_in_progress = false
        
        // The managedsoftwareupdate run will have changed state preferences
        // in ManagedInstalls.plist. Load the new values.
        reloadPrefs()
        let lastCheckResult = pref("LastCheckResult") as? Int ?? 0
        if sessionResult != 0 || lastCheckResult < 0 {
            var alertMessageText = NSLocalizedString(
                "Update check failed", comment: "Update Check Failed title")
            var detailText = ""
            if tasktype == "installwithnologout" {
                msc_log("MSC", "cant_update", msg: "Install session failed")
                alertMessageText = NSLocalizedString(
                    "Install session failed", comment: "Install Session Failed title")
            }
            if sessionResult == -1 {
                // connection was dropped unexpectedly
                msc_log("MSC", "cant_update", msg: "unexpected process end")
                detailText = NSLocalizedString(
                    ("There is a configuration problem with the managed " +
                     "software installer. The process ended unexpectedly. " +
                     "Contact your systems administrator."),
                    comment: "Unexpected Session End message")
            } else if sessionResult == -2 {
                // session never started
                msc_log("MSC", "cant_update", msg: "process did not start")
                detailText = NSLocalizedString(
                    ("There is a configuration problem with the managed " +
                     "software installer. Could not start the process. " +
                     "Contact your systems administrator."),
                    comment: "Could Not Start Session message")
            } else if lastCheckResult == -1 {
                // server not reachable
                msc_log("MSC", "cant_update", msg: "cannot contact server")
                detailText = NSLocalizedString(
                    ("Managed Software Center cannot contact the update " +
                     "server at this time.\n" +
                     "Try again later. If this situation continues, " +
                     "contact your systems administrator."),
                    comment: "Cannot Contact Server detail")
            } else if lastCheckResult == -2 {
                // preflight failed
                msc_log("MSU", "cant_update", msg: "failed preflight")
                detailText = NSLocalizedString(
                    ("Managed Software Center cannot check for updates now.\n" +
                     "Try again later. If this situation continues, " +
                     "contact your systems administrator."),
                    comment: "Failed Preflight Check detail")
            }
            // show the alert sheet
            self.window!.makeKeyAndOrderFront(self)
            let alert = NSAlert()
            alert.messageText = alertMessageText
            alert.informativeText = detailText
            alert.addButton(withTitle: NSLocalizedString("OK", comment:"OK button title"))
            alert.beginSheetModal(for: self.window!, completionHandler: { (modalResponse) -> Void in
                self.resetAndReload()
            })
            return
        }
        if tasktype == "checktheninstall" {
            clearMunkiItemsCache()
            // possibly check again if choices have changed
            updateNow()
            return
        }
        
        // all done checking and/or installing: display results
        resetAndReload()
        
        if updateCheckNeeded() {
            // more stuff pending? Let's do it...
            updateNow()
        }
    }
            
    func resetAndReload() {
        // Clear cached values, reload from disk. Display any changes.
        // Typically called soon after a managedsoftwareupdate session completes
        msc_debug_log("resetAndReload method called")
        // need to clear out cached data
        clearMunkiItemsCache()
        // recache SelfService choices
        cached_self_service = SelfService()
        // copy any new custom client resources
        get_custom_resources()
        // pending updates may have changed
        _alertedUserToOutstandingUpdates = false
        // enable/disable controls as needed
        enableOrDisableSoftwareViewControls()
        // what page are we currently viewing?
        let page_url = webView.mainFrameURL ?? ""
        let filename = URL(string: page_url)?.lastPathComponent ?? ""
        let name = (filename as NSString).deletingPathExtension
        let key = name.components(separatedBy: "-")[0]
        switch key {
        case "detail", "updatedetail":
            // item detail page
            webView.reload(self)
        case "category", "filter", "developer":
            // optional item list page
            updateListPage()
        case "categories":
            // categories page
            updateCategoriesPage()
        case "myitems":
            // my items page
            updateMyItemsPage()
        case "updates":
            // updates page
            webView.reload(self)
            _alertedUserToOutstandingUpdates = true
        default:
            // should never get here
            msc_debug_log("Unexpected value for page name: \(filename)")
        }
        // update count might have changed
        displayUpdateCount()
    }
    
    // Begin NSWindowDelegate methods
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // NSWindowDelegate method called when user closes a window
        // for us, closing the main window should be the same as quitting
        NSApp.terminate(self)
        return false
    }
    
    func windowDidBecomeMain(_ notification: Notification) {
        // Our window was activated, make sure controls enabled as needed
        let enabled_state = (getOptionalInstallItems().count > 0)
        enableOrDisableToolbarButtons(enabled_state)
    }
    
    func windowDidResignMain(_ notification: Notification) {
        // Our window was deactivated, make sure controls enabled as needed
        enableOrDisableToolbarButtons(false)
    }
    
    // End NSWindowDelegate methods
    
    override func awakeFromNib() {
        // Stuff we need to intialize when we start
        super.awakeFromNib()
        webView.drawsBackground = false
        webView.uiDelegate = self
        webView.frameLoadDelegate = self
        webView.resourceLoadDelegate = self
        webView.policyDelegate = self
        setNoPageCache()
        alert_controller = MSCAlertController()
        alert_controller.window = self.window
        htmlDir = html_dir()
        registerForNotifications()
    }
    
    func registerForNotifications() {
        // register for notification messages
        // register for notification if available updates change
        let nc = DistributedNotificationCenter.default()
        nc.addObserver(self,
                       selector: #selector(self.updateAvailableUpdates(_:)),
                       name: NSNotification.Name(
                            rawValue: "com.googlecode.munki.managedsoftwareupdate.updateschanged"),
                       object: nil,
                       suspensionBehavior: .deliverImmediately)
        //register for notification to display a logout warning
        // from the logouthelper
        nc.addObserver(self,
                       selector: #selector(self.forcedLogoutWarning(_:)),
                       name: NSNotification.Name(
                            rawValue: "com.googlecode.munki.ManagedSoftwareUpdate.logoutwarn"),
                       object: nil,
                       suspensionBehavior: .deliverImmediately)
    }
    
    @objc func updateAvailableUpdates(_ notification: Notification) {
        // If a Munki session is not in progress (that we know of) and
        // we get a updateschanged notification, resetAndReload
        msc_debug_log("Managed Software Center got update notification")
        if !_update_in_progress {
            resetAndReload()
        }
    }
    
    @objc func forcedLogoutWarning(_ notification: Notification) {
        // Received a logout warning from the logouthelper for an
        // upcoming forced install
        msc_debug_log("Managed Software Center got forced logout warning")
        // got a notification of an upcoming forced install
        // switch to updates view, then display alert
        loadUpdatesPage(self)
        alert_controller.forcedLogoutWarning(notification)
    }
    
    @objc func checkForUpdates(suppress_apple_update_check: Bool = false) {
        // start an update check session
        if _update_in_progress {
            return
        }
        if startUpdateCheck(suppress_apple_update_check) {
            _update_in_progress = true
            displayUpdateCount()
            managedsoftwareupdate_task = "manualcheck"
            if let status_controller = (NSApp.delegate as? AppDelegate)?.statusController {
                status_controller.startMunkiStatusSession()
            }
            markRequestedItemsAsProcessing()
        } else {
            munkiStatusSessionEnded(2)
        }
    }
    
    @IBAction func reloadPage(_ sender: Any) {
        // User selected Reload page menu item. Reload the page and kick off an updatecheck
        msc_log("user", "reload_page_menu_item_selected")
        checkForUpdates()
        webView.reload(sender)
    }
    
    func kickOffInstallSession() {
        // start an update install/removal session
        
        // check for need to logout, restart, firmware warnings
        // warn about blocking applications, etc...
        // then start an update session
        if updatesRequireRestart() || updatesRequireLogout() {
            if !currentPageIsUpdatesPage() {
                // switch to updates view
                loadUpdatesPage(self)
            }
            // warn about need to logout or restart
            alert_controller.confirmUpdatesAndInstall()
        } else {
            if alert_controller.alertedToBlockingAppsRunning() {
                loadUpdatesPage(self)
                return
            }
            if alert_controller.alertedToRunningOnBatteryAndCancelled() {
                loadUpdatesPage(self)
                return
            }
            managedsoftwareupdate_task = ""
            msc_log("user", "install_without_logout")
            _update_in_progress = true
            displayUpdateCount()
            if let status_controller = (NSApp.delegate as? AppDelegate)?.statusController {
                status_controller._status_message = NSLocalizedString(
                    "Updating...", comment: "Updating message")
            }
            if justUpdate() {
                managedsoftwareupdate_task = "installwithnologout"
                if let status_controller = (NSApp.delegate as? AppDelegate)?.statusController {
                    status_controller.startMunkiStatusSession()
                }
                markPendingItemsAsInstalling()
            } else {
                msc_debug_log("Error starting install session")
                munkiStatusSessionEnded(2)
            }
        }
    }
    
    func markPendingItemsAsInstalling() {
        // While an install/removal session is happening, mark optional items
        // that are being installed/removed with the appropriate status
        msc_debug_log("marking pendingItems as installing")
        let install_info = getInstallInfo()
        let managed_installs = install_info["managed_installs"] as? [PlistDict] ?? [PlistDict]()
        let removals = install_info["removals"] as? [PlistDict] ?? [PlistDict]()
        let items_to_be_installed_names = managed_installs.filter(
            {$0["name"] != nil}).map({$0["name"] as! String})
        let items_to_be_removed_names = removals.filter(
            {$0["name"] != nil}).map({$0["name"] as! String})
        for name in items_to_be_installed_names {
            // remove names for user selections since we are installing
            user_install_selections.remove(name)
        }
        for name in items_to_be_removed_names {
            // remove names for user selections since we are removing
            user_removal_selections.remove(name)
        }
        for item in getOptionalInstallItems() {
            var new_status = ""
            if let name = item["name"] as? String {
                if items_to_be_installed_names.contains(name) {
                    msc_debug_log("Setting status for \(name) to \"installing\"")
                    new_status = "installing"
                } else if items_to_be_removed_names.contains("name") {
                    msc_debug_log("Setting status for \(name) to \"removing\"")
                    new_status = "removing"
                }
            }
            if !new_status.isEmpty {
                item["status"] = new_status
                updateDOMforOptionalItem(item)
            }
        }
    }
    
    func markRequestedItemsAsProcessing() {
        // When an update check session is happening, mark optional items
        // that have been requested as processing
        msc_debug_log("marking requested items as processing")
        for item in getOptionalInstallItems() {
            var new_status = ""
            let name = item["name"] as? String ?? ""
            if item["status"] as? String == "install-requested" {
                msc_debug_log("Setting status for \(name) to \"downloading\"")
                new_status = "downloading"
            } else if item["status"] as? String == "removal-requested" {
                msc_debug_log("Setting status for \(name) to \"preparing-removal\"")
                new_status = "preparing-removal"
            }
            if !new_status.isEmpty {
                item["status"] = new_status
                updateDOMforOptionalItem(item)
            }
        }
    }
    
    func updateNow() {
        /* If user has added to/removed from the list of things to be updated,
         run a check session. If there are no more changes, proceed to an update
         installation session if items to be installed/removed are exclusively
         those selected by the user in this session */
        if stop_requested {
            // reset the flag
            stop_requested = false
            resetAndReload()
            return
        }
        if updateCheckNeeded() {
            // any item status changes that require an update check?
            msc_debug_log("updateCheck needed")
            msc_log("user", "check_then_install_without_logout")
            // since we are just checking for changed self-service items
            // we can suppress the Apple update check
            _update_in_progress = true
            displayUpdateCount()
            if startUpdateCheck(true) {
                managedsoftwareupdate_task = "checktheninstall"
                if let status_controller = (NSApp.delegate as? AppDelegate)?.statusController {
                    status_controller.startMunkiStatusSession()
                }
                markRequestedItemsAsProcessing()
            } else {
                msc_debug_log("Error starting check-then-install session")
                munkiStatusSessionEnded(2)
            }
        } else if !_alertedUserToOutstandingUpdates && updatesContainNonUserSelectedItems() {
            // current list of updates contains some not explicitly chosen by
            // the user
            msc_debug_log("updateCheck not needed, items require user approval")
            _update_in_progress = false
            displayUpdateCount()
            loadUpdatesPage(self)
            alert_controller.alertToExtraUpdates()
        } else {
            msc_debug_log("updateCheck not needed")
            _alertedUserToOutstandingUpdates = false
            kickOffInstallSession()
        }
    }
    
    func getUpdateCount() -> Int {
        // Get the count of effective updates
        if _update_in_progress {
            return 0
        }
        return getEffectiveUpdateList().count
    }
    
    func displayUpdateCount() {
        // Display the update count as a badge in the window toolbar
        // and as an icon badge in the Dock
        let updateCount = getUpdateCount()
        let btn_image = MSCBadgedTemplateImage.image(named: NSImage.Name(rawValue: "updatesTemplate.pdf"),
                                                     withCount: updateCount)
        updateButtonCell.image = btn_image
        if updateCount > 0 {
            NSApp.dockTile.badgeLabel = String(updateCount)
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }
    
    func updateMyItemsPage() {
        // Update the "My Items" page with current data.
        // Modifies the DOM to avoid ugly browser refresh
        let myitems_rows = buildMyItemsRows()
        let document = webView.mainFrameDocument
        if let table_body_element = document?.getElementById("my_items_rows") {
            table_body_element.innerHTML = myitems_rows
        }
    }
    
    func updateCategoriesPage() {
        // Update the Catagories page with current data.
        // Modifies the DOM to avoid ugly browser refresh
        let items_html = buildCategoryItemsHTML()
        let document = webView.mainFrameDocument
        if let items_div_element = document?.getElementById("optional_installs_items") {
            items_div_element.innerHTML = items_html
        }
    }
    
    func updateListPage() {
        // Update the optional items list page with current data.
        // Modifies the DOM to avoid ugly browser refresh
        let page_url = webView.mainFrameURL ?? ""
        let filename = URL(string: page_url)?.lastPathComponent ?? ""
        let name = ((filename as NSString).deletingPathExtension) as String
        let components = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(components[0])
        let value = String(components.count > 1 ? components[1] : "")
        var category = ""
        var our_filter = ""
        var developer = ""
        if key == "category" {
             if value != "all" {
                category = value
             }
        } else if key == "filter" {
            our_filter = value
        } else if key == "developer" {
            developer = value
        } else {
            msc_debug_log("updateListPage unexpected error: current page filename is \(filename)")
            return
        }
        msc_debug_log("updating software list page with " +
                      "category: '\(category)', developer: '\(developer)', " +
                      "filter: '\(our_filter)'")
        let items_html = buildListPageItemsHTML(
            category: category, developer: developer, filter: our_filter)
        let document = webView.mainFrameDocument
        if let items_div_element = document?.getElementById("optional_installs_items") {
            items_div_element.innerHTML = items_html
        }
    }
    
    func load_page(_ url_fragment: String) {
        // Tells the WebView to load the appropriate page
        msc_debug_log("load_page request for \(url_fragment)")
        let html_file = NSString.path(withComponents: [htmlDir, url_fragment])
        let request = URLRequest(url: URL(fileURLWithPath: html_file),
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: TimeInterval(10.0))
        webView.mainFrame.load(request)
        if url_fragment == "updates.html" {
            // clear all earlier update notifications
            NSUserNotificationCenter.default.removeAllDeliveredNotifications()
        }
    }
    
    func setNoPageCache() {
        /* We disable the back/forward page cache because
         we generate each page dynamically; we want things
         that are changed in one page view to be reflected
         immediately in all page views */
        let identifier = "com.googlecode.munki.ManagedSoftwareCenter"
        if let prefs = WebPreferences(identifier: identifier) {
            prefs.usesPageCache = false
            webView.preferencesIdentifier = identifier
        }
    }
    
    // WebPolicyDelegate methods
    
    func webView(_ webView: WebView!,
                 decidePolicyForNewWindowAction actionInformation: [AnyHashable : Any]!,
                 request: URLRequest!,
                 newFrameName frameName: String!,
                 decisionListener listener: WebPolicyDecisionListener!) {
        // if the request is to open the link in a new window,
        // open link in default browser instead of in our app's WebView
        listener.ignore()
        if let the_url = request.url {
            NSWorkspace.shared.open(the_url)
        }
    }
    
    func webView(_ webView: WebView!,
                 decidePolicyForMIMEType type: String!,
                 request: URLRequest!,
                 frame: WebFrame!,
                 decisionListener listener: WebPolicyDecisionListener!) {
        // Decide whether to show or download content
        if WebView.canShowMIMEType(type) {
            listener.use()
        } else {
            // send the request to the user's default browser instead, where it
            // can display or download it
            listener.ignore()
            if let the_url = request.url {
                NSWorkspace.shared.open(the_url)
            }
        }
    }
    
    // WebResourceLoadDelegate methods
    
    func webView(_ sender: WebView!,
                 resource identifier: Any!,
                 willSend request: URLRequest!,
                 redirectResponse: URLResponse!,
                 from dataSource: WebDataSource!) -> URLRequest! {
        // By reacting to this delegate notification, we can build the page
        // the WebView wants to load'''
        msc_debug_log(
            "webView:resource:willSendRequest:redirectResponse:fromDataSource:")
        if let url = request.url, let scheme = url.scheme {
            msc_debug_log("Got URL scheme: \(scheme)")
            if scheme == NSURLFileScheme {
                let path = url.path
                msc_debug_log("Request path is \(path)")
                if path.hasPrefix(htmlDir) && url.pathExtension == "html" {
                    let filename = url.lastPathComponent
                    if (filename.hasPrefix("detail-") ||
                            filename.hasPrefix("category-") ||
                            filename.hasPrefix("filter-") ||
                            filename.hasPrefix("developer-") ||
                            filename.hasPrefix("updatedetail-") ||
                            filename == "myitems.html" ||
                            filename == "updates.html" ||
                            filename == "categories.html") {
                        do {
                            try buildPage(filename)
                        } catch {
                            msc_debug_log(
                                "Could not build page for \(filename): \(error)")
                        }
                    }
                }
            }
        }
        return request
    }
    
    // WebFrameLoadDelegate methods
    
    func webView(_ webView: WebView!,
                 didClearWindowObject windowObject: WebScriptObject!,
                 for frame: WebFrame!) {
        // Configure webView to let JavaScript talk to this object.
        windowObject.setValue(self, forKey: "AppController")
    }
    
    func webView(_ sender: WebView!, didStartProvisionalLoadFor frame: WebFrame!) {
        // Animate progress spinner while we load a page and highlight the
        // proper toolbar button
        progressSpinner.startAnimation(self)
        if let main_url = URL(string: webView.mainFrameURL) {
            let pagename = main_url.lastPathComponent
            msc_debug_log("Requested pagename is \(pagename)")
            if (pagename == "category-all.html" ||
                    pagename.hasPrefix("detail-") ||
                    pagename.hasPrefix("filter-") ||
                    pagename.hasPrefix("developer-")) {
                highlightToolbarButtons("Software")
            } else if pagename == "categories.html" || pagename.hasPrefix("category-") {
                highlightToolbarButtons("Categories")
            } else if pagename == "myitems.html" {
                highlightToolbarButtons("My Items")
            } else if pagename == "updates.html" || pagename.hasPrefix("updatedetail-") {
                highlightToolbarButtons("Updates")
            } else {
                // no idea what type of item it is
                highlightToolbarButtons("")
            }
        }
    }
    
    func webView(_ sender: WebView!, didFinishLoadFor frame: WebFrame!) {
        progressSpinner.stopAnimation(self)
        navigateBackButton.isEnabled = webView.canGoBack
        navigateForwardButton.isEnabled = webView.canGoForward
    }
    
    func webView(_ sender: WebView!, didFailProvisionalLoadWithError error: Error!, for frame: WebFrame!) {
        // Stop progress spinner and log
        progressSpinner.stopAnimation(self)
        msc_debug_log("Provisional load error: \(error)")
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: htmlDir)
             msc_debug_log("Files in html_dir: \(files)")
        } catch {
            // ignore
        }
    }
    
    func webView(_ sender: WebView!, didFailLoadWithError error: Error!, for frame: WebFrame!) {
        // Stop progress spinner and log error
        progressSpinner.stopAnimation(self)
        msc_debug_log("Committed load error: \(error)")
    }
    
    // WebView uiDelegate methods
    // (none currently)
    
    // JavaScript integration -- WebScripting methods
    
    /*override class func webScriptName(for selector: Selector!) -> String! {
        if selector == #selector(self.changeSelectedCategory(_:)) {
            return "changeSelectedCategory"
        } else {
            return nil
        }
    }*/
    
    override class func isSelectorExcluded(fromWebScript selector: Selector!) -> Bool {
        let allowedSelectors = [
            #selector(self.openExternalLink(_:)),
            #selector(self.installButtonClicked),
            #selector(self.updateOptionalInstallButtonClicked(_:)),
            #selector(self.myItemsActionButtonClicked(_:)),
            #selector(self.actionButtonClicked(_:)),
            #selector(self.updateOptionalInstallButtonFinishAction(_:)),
            #selector(self.changeSelectedCategory(_:))
        ]
        if allowedSelectors.contains(selector) {
            return false // this selector is not excluded
        } else {
            return true // all other selectors are excluded
        }
    }
    
    // handling DOM UI elements
    
    @objc func openExternalLink(_ url: String) {
        // open a link in the default browser
        if let real_url = URL(string: url) {
            NSWorkspace.shared.open(real_url)
        }
    }
    
    @objc func installButtonClicked() {
        // this method is called from JavaScript when the user
        // clicks the Install button in the Updates view
        if _update_in_progress {
            // this is now a stop/cancel button
            msc_log("user", "cancel_updates")
            if let status_controller = (NSApp.delegate as? AppDelegate)?.statusController {
                status_controller.disableStopButton()
                status_controller._status_stopBtnState = 1
            }
            stop_requested = true
            // send a notification that stop button was clicked
            let stop_request_flag_file = "/private/tmp/com.googlecode.munki.managedsoftwareupdate.stop_requested"
            if !FileManager.default.fileExists(atPath: stop_request_flag_file) {
                FileManager.default.createFile(atPath: stop_request_flag_file, contents: nil, attributes: nil)
            }
        } else if getUpdateCount() == 0 {
            // no updates, the button must say "Check Again"
            msc_log("user", "refresh_clicked")
            checkForUpdates()
        } else {
            // button must say "Update"
            // we're on the Updates page, so users can see all the pending/
            // outstanding updates
            _alertedUserToOutstandingUpdates = true
            updateNow()
        }
    }
    
    @objc func updateOptionalInstallButtonClicked(_ item_name: String) {
        // this method is called from JavaScript when a user clicks
        // the cancel or add button in the updates list
        if let item = optionalItem(forName: item_name) {
            if (item["status"] as? String ?? "" == "update-available" &&
                    item["preupgrade_alert"] != nil) {
                displayPreInstallUninstallAlert(item["preupgrade_alert"] as? PlistDict ?? PlistDict(),
                                                action: updateOptionalInstallButtonBeginAction,
                                                item: item_name)
            } else {
                updateOptionalInstallButtonBeginAction(item_name)
            }
        } else {
            msc_debug_log("Unexpected error: Can't find item for \(item_name)")
        }
    }
    
    func updateOptionalInstallButtonBeginAction(_ item_name: String) {
        if let scriptObject = webView.windowScriptObject {
            let args = [item_name]
            scriptObject.callWebScriptMethod("fadeOutAndRemove", withArguments: args)
        }
    }
    
    @objc func myItemsActionButtonClicked(_ item_name: String) {
        // this method is called from JavaScript when the user clicks
        // the Install/Remove/Cancel button in the My Items view
        if let item = optionalItem(forName: item_name) {
            if (item["status"] as? String ?? "" == "installed" &&
                    item["preuninstall_alert"] != nil) {
                displayPreInstallUninstallAlert(item["preuninstall_alert"] as? PlistDict ?? PlistDict(),
                                                action: myItemsActionButtonPerformAction,
                                                item: item_name)
            } else {
                myItemsActionButtonPerformAction(item_name)
            }
        } else {
            msc_debug_log("Unexpected error: Can't find item for \(item_name)")
        }
    }
    
    func myItemsActionButtonPerformAction(_ item_name: String) {
        // perform action needed when user clicks
        // the Install/Remove/Cancel button in the My Items view
        guard let item = optionalItem(forName: item_name) else {
            msc_debug_log(
                "User clicked MyItems action button for \(item_name)")
            msc_debug_log("Could not find item for \(item_name)")
            return
        }
        guard let document = webView.mainFrameDocument else {
            msc_debug_log(
                "User clicked MyItems action button for \(item_name)")
            msc_debug_log("Could not get webView.mainFrameDocument")
            return
        }
        guard let status_line = document.getElementById("\(item_name)_status_text") else {
            msc_debug_log(
                "User clicked MyItems action button for \(item_name)")
            msc_debug_log("Unexpected error finding \(item_name)_status_text")
            return
        }
        guard let btn = document.getElementById("\(item_name)_action_button_text") else {
            msc_debug_log(
                "User clicked MyItems action button for \(item_name)")
            msc_debug_log("Unexpected error finding \(item_name)_action_button_text")
            return
        }
        let prior_status = item["status"] as? String ?? ""
        if !update_status_for_item(item) {
            // there was a problem, can't continue
            return
        }
        displayUpdateCount()
        let current_status = item["status"] as? String ?? ""
        if current_status == "not-installed" {
            // we removed item from list of things to install
            // now remove from display
            if let table_row = document.getElementById("\(item_name)_myitems_table_row") {
                table_row.parent.removeChild(table_row)
            } else {
                (btn as! DOMHTMLElement).innerText = item["myitem_action_text"] as? String ?? ""
                (status_line as! DOMHTMLElement).innerText = item["myitem_status_text"] as? String ?? ""
                status_line.className = "status \(current_status)"
            }
            if ["install-requested", "removal-requested"].contains(current_status) {
                _alertedUserToOutstandingUpdates = false
                if !_update_in_progress {
                    updateNow()
                }
            } else if ["will-be-installed", "update-will-be-installed",
                       "will-be-removed"].contains(prior_status) {
                // cancelled a pending install or removal; should run an updatecheck
                checkForUpdates(suppress_apple_update_check: true)
            }
        }
    }
    
    @objc func actionButtonClicked(_ item_name: String) {
        // this method is called from JavaScript when the user clicks
        // the Install/Removel/Cancel button in the list or detail view
        if let item = optionalItem(forName: item_name) {
            var showAlert = true
            let status = item["status"] as? String ?? ""
            if status == "not-installed" && item["preinstall_alert"] != nil {
                displayPreInstallUninstallAlert(item["preinstall_alert"] as? PlistDict ?? PlistDict(),
                                                action: actionButtonPerformAction,
                                                item: item_name)
            } else if status == "installed" && item["preuninstall_alert"] != nil {
                displayPreInstallUninstallAlert(item["preuninstall_alert"] as? PlistDict ?? PlistDict(),
                                                action: actionButtonPerformAction,
                                                item: item_name)
            } else if status == "update-available" && item["preupgrade_alert"] != nil {
                displayPreInstallUninstallAlert(item["preupgrade_alert"] as? PlistDict ?? PlistDict(),
                                                action: actionButtonPerformAction,
                                                item: item_name)
            } else {
                actionButtonPerformAction(item_name)
                showAlert = false
            }
            if showAlert {
                msc_log("user", "show_alert")
            }
        } else {
            msc_debug_log(
                "User clicked Install/Remove/Upgrade/Cancel button in the list " +
                "or detail view")
            msc_debug_log("Unexpected error: Can't find item for \(item_name)")
        }
    }
    
    func displayPreInstallUninstallAlert(_ alert: PlistDict, action: @escaping (String)->Void, item: String) {
        // Display an alert sheet before processing item install/upgrade
        // or uninstall
        let defaultAlertTitle = NSLocalizedString(
            "Attention", comment:"Pre Install Uninstall Upgrade Alert Title")
        let defaultAlertDetail = NSLocalizedString(
            "Some conditions apply to this software. " +
            "Please contact your administrator for more details",
            comment: "Pre Install Uninstall Upgrade Alert Detail")
        let defaultOKLabel = NSLocalizedString(
            "OK", comment: "Pre Install Uninstall Upgrade OK Label")
        let defaultCancelLabel = NSLocalizedString(
            "Cancel", comment: "Pre Install Uninstall Upgrade Cancel Label")
        
        let alertTitle = alert["alert_title"] as? String ?? defaultAlertTitle
        let alertDetail = alert["alert_detail"] as? String ?? defaultAlertDetail
        let OKLabel = alert["ok_label"] as? String ?? defaultOKLabel
        let cancelLabel = alert["cancel_label"] as? String ?? defaultCancelLabel
        
        // show the alert sheet
        self.window?.makeKeyAndOrderFront(self)
        let alert = NSAlert()
        alert.messageText = alertTitle
        alert.informativeText = alertDetail
        alert.addButton(withTitle: cancelLabel)
        alert.addButton(withTitle: OKLabel)
        alert.beginSheetModal(for: self.window!,
                              completionHandler: ({ (modalResponse) -> Void in
            if modalResponse == .alertFirstButtonReturn {
                // default is to cancel!
                msc_log("user", "alert_canceled")
            } else if modalResponse == .alertSecondButtonReturn {
                msc_log("user", "alert_accepted")
                // run our completion function
                action(item)
            }
        }))
    }
    
    func actionButtonPerformAction(_ item_name: String) {
        // Perform the action requested when clicking the action button
        // in the list or detail view
        if let item = optionalItem(forName: item_name) {
            let prior_status = item["status"] as? String ?? ""
            if !update_status_for_item(item) {
                // there was a problem, can't continue
                return
            }
            let current_status = item["status"] as? String ?? ""
            //msc_log("user", "action_button_\(current_status)", item_name)
            displayUpdateCount()
            updateDOMforOptionalItem(item)
            
            if ["install-requested", "removal-requested"].contains(current_status) {
                _alertedUserToOutstandingUpdates = false
                if !_update_in_progress {
                    updateNow()
                }
            } else if ["will-be-installed", "update-will-be-installed",
                       "will-be-removed"].contains(prior_status) {
                // cancelled a pending install or removal; should run an updatecheck
                checkForUpdates(suppress_apple_update_check: true)
            }
        } else {
            msc_debug_log(
                "User clicked Install/Upgrade/Removal/Cancel button " +
                "in the list or detail view")
            msc_debug_log("Can't find item: \(item_name)")
            return
        }
    }
    
    func update_status_for_item(_ item: OptionalItem) -> Bool {
        /* Attempts to update an item's status; displays an error dialog
         if SelfServeManifest is not writable.
         Returns a boolean to indicate success */
        if item.update_status() {
            return true
        } else {
            let errMsg = "Could not update \(WRITEABLE_SELF_SERVICE_MANIFEST_PATH)"
            msc_debug_log(errMsg)
            let alertTitle = NSLocalizedString(
                "System configuration problem",
                comment: "System configuration problem alert title")
            let alertDetail = NSLocalizedString(
                "A systems configuration issue is preventing Managed Software " +
                "Center from operating correctly. The reported issue is: ",
                comment: "System configuration problem alert detail") + "\n" + errMsg
            let alert = NSAlert()
            alert.messageText = alertTitle
            alert.informativeText = alertDetail
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button title"))
            alert.runModal()
            return false
        }
    }
    
    @objc func updateOptionalInstallButtonFinishAction(_ item_name: String) {
        // Perform the required action when a user clicks
        // the cancel or add button in the updates list
        guard let document = webView.mainFrameDocument else {
            msc_debug_log("Could not get webView.mainFrameDocument")
            return
        }
        guard let item = optionalItem(forName: item_name) else {
            msc_debug_log(
                "Unexpected error: Can't find item for \(item_name)")
            return
        }
        guard let update_table_row = document.getElementById(
            "\(item_name)_update_table_row") else {
                msc_debug_log(
                    "Unexpected error: Can't find \(item_name)_update_table_row")
                return
        }
        // remove this row from its current table
        update_table_row.parent.removeChild(update_table_row)
        
        //let previous_status = item["status"] as? String ?? ""
        // update item status
        if !update_status_for_item(item) {
            // there was a problem, can't continue
            msc_debug_log(
                "Unexpected error: Can't update status of \(item_name)")
            return
        }
        
        let current_status = item["status"] as? String ?? ""
        msc_log("user", "optional_install_\(current_status)", msg: item_name)
        if item["needs_update"] as? Bool ?? false {
            // make some new HTML for the updated item
            let item_template = getTemplate("update_row_template.html")
            let item_html = item_template.substitute(item)
            var table: DOMElement?
            if ["install-requested",
                    "update-will-be-installed", "installed"].contains(current_status) {
                // add the node to the updates-to-install table
                table = document.getElementById("updates-to-install-table")
            }
            if current_status == "update-available" {
                // add the node to the other-updates table
                table = document.getElementById("other-updates-table")
            }
            if table == nil {
                msc_debug_log(
                    "Unexpected error: could not find updates-to-install-table or other-updates-table")
                return
            }
            // this isn't the greatest way to add something to the DOM
            // but it works...
            table!.innerHTML = table!.innerHTML + item_html
        }
        
        // might need to toggle visibility of other updates div
        if let other_updates_div = document.getElementById("other-updates") {
            var other_updates_div_classes = other_updates_div.className.components(separatedBy: " ")
            let other_updates_table_html = (document.getElementById("other-updates-table")?.innerHTML ?? "")
            let other_updates_table_html_trimmed = other_updates_table_html.trimmingCharacters(in: .whitespacesAndNewlines)
            if !other_updates_table_html_trimmed.isEmpty {
                // remove
                other_updates_div_classes = other_updates_div_classes.filter({ $0 != "hidden" })
                other_updates_div.className = other_updates_div_classes.joined(separator: " ")
            } else {
                if !other_updates_div_classes.contains("hidden") {
                    other_updates_div_classes.append("hidden")
                    other_updates_div.className = other_updates_div_classes.joined(separator: " ")
                }
            }
        }
        
        // update the updates-to-install header to reflect the new list of
        // updates to install
        if let update_count_element = document.getElementById("update-count-string") {
            (update_count_element as! DOMHTMLElement).innerText = updateCountMessage(getUpdateCount())
        }
        if let warning_text_element = document.getElementById("update-warning-text") {
            (warning_text_element as! DOMHTMLElement).innerText = getWarningText()
        }
    
        // update text of Install All button
        if let install_all_button_element = document.getElementById("install-all-button-text") {
            (install_all_button_element as! DOMHTMLElement).innerText = getInstallAllButtonTextForCount(getUpdateCount())
        }
        
        // update count badges
        displayUpdateCount()
        
        if updateCheckNeeded() {
            // check for updates after a short delay so UI changes visually
            // complete first
            self.perform(#selector(self.checkForUpdates), with: true, afterDelay: 1.0)
        }
    }
    
    func updateDOMforOptionalItem(_ item: OptionalItem) {
        // Update displayed status of an item
        let item_name = item["name"] as? String ?? ""
        guard let document = webView.mainFrameDocument else {
            msc_debug_log("ERROR in updateDOMforOptionalItem: could not get mainFrameDocument")
            return
        }
        guard let status_line = document.getElementById("\(item_name)_status_text") else {
            msc_debug_log("ERROR in updateDOMforOptionalItem: could not find \(item_name)_status_text in DOM")
            return
        }
        guard let btn = document.getElementById("\(item_name)_action_button_text") else {
            msc_debug_log("ERROR in updateDOMforOptionalItem: could not find \(item_name)_action_button_text in DOM")
            return
        }
        
        var btn_classes = btn.className.components(separatedBy: " ")
        // filter out status class
        btn_classes = btn_classes.filter(
            { ["msc-button-inner", "large", "small", "install-updates"].contains($0) }
        )
        if let item_status = item["status"] as? String {
            btn_classes.append(item_status)
            btn.className = btn_classes.joined(separator: " ")
            status_line.className = item_status
        }
        if btn_classes.contains("install-updates") {
            (btn as! DOMHTMLElement).innerText = item["myitem_action_text"] as? String ?? ""
        } else if btn_classes.contains("long_action_text") {
            (btn as! DOMHTMLElement).innerText = item["long_action_text"] as? String ?? ""
        } else {
            (btn as! DOMHTMLElement).innerText = item["short_action_text"] as? String ?? ""
        }
        if let status_text_span = document.getElementById("\(item_name)_status_text_span") {
            // use setInnerHTML_ instead of setInnerText_ because sometimes the status
            // text contains html, like '<span class="warning">Some warning</span>'
            status_text_span.innerHTML = item["status_text"] as? String ?? ""
        }
    }
    
    @objc func changeSelectedCategory(_ category: String) {
        // this method is called from JavaScript when the user
        // changes the category selected in the sidebar popup
        let all_categories_label = NSLocalizedString(
            "All Categories", comment: "AllCategoriesLabel")
        let featured_label = NSLocalizedString("Featured", comment: "FeaturedLabel")
        if [all_categories_label, featured_label].contains(category) {
            load_page("category-all.html")
        } else {
            load_page("category-\(category).html")
        }
    }
    
    // some Cocoa UI bindings
    @IBAction func showHelp(_ sender: Any) {
        if let helpURL = pref("HelpURL") as? String {
            if let finalURL = URL(string: helpURL) {
                NSWorkspace.shared.open(finalURL)
            }
        } else {
            let alertTitle = NSLocalizedString("Help", comment: "No help alert title")
            let alertDetail = NSLocalizedString(
                "Help isn't available for Managed Software Center.",
                comment: "No help alert detail")
            let alert = NSAlert()
            alert.messageText = alertTitle
            alert.informativeText = alertDetail
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button title"))
            alert.runModal()
        }
    }
    
    @IBAction func navigateBackBtnClicked(_ sender: Any) {
        // Handle WebView back button
        webView.goBack(self)
    }
    
    @IBAction func navigateForwardBtnClicked(_ sender: Any) {
        // Handle WebView forward button
        webView.goForward(self)
    }
    
    @IBAction func loadAllSoftwarePage(_ sender: Any) {
        // Called by Navigate menu item
        load_page("category-all.html")
    }
    
    @IBAction func loadCategoriesPage(_ sender: Any) {
        // Called by Navigate menu item
        load_page("categories.html")
    }
    
    @IBAction func loadMyItemsPage(_ sender: Any) {
        // Called by Navigate menu item'''
        load_page("myitems.html")
    }
    
    @IBAction func loadUpdatesPage(_ sender: Any) {
        // Called by Navigate menu item'''
        load_page("updates.html")
        _alertedUserToOutstandingUpdates = true
    }
    
    @IBAction func softwareToolbarButtonClicked(_ sender: Any) {
        // User clicked Software toolbar button
        loadAllSoftwarePage(sender)
    }
    
    @IBAction func categoriesToolbarButtonClicked(_ sender: Any) {
        // User clicked Categories toolbar button'''
        loadCategoriesPage(sender)
    }
    
    @IBAction func myItemsToolbarButtonClicked(_ sender: Any) {
        // User clicked My Items toolbar button'''
        loadMyItemsPage(sender)
    }
    
    @IBAction func updatesToolbarButtonClicked(_ sender: Any) {
        // User clicked Updates toolbar button'''
        loadUpdatesPage(sender)
    }
    
    @IBAction func searchFilterChanged(_ sender: Any) {
        // User changed the search field
        let filterString = searchField.stringValue.lowercased()
        if !filterString.isEmpty {
            msc_debug_log("Search filter is: \(filterString)")
            load_page("filter-\(filterString).html")
        }
    }
}