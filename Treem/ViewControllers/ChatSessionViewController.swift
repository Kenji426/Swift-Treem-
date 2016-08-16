//
//  ChatSessionViewController.swift
//  Treem
//
//  Created by Daniel Sorrell on 2/12/16.
//  Copyright © 2016 Treem LLC. All rights reserved.
//

import UIKit
import CLImageEditor
import TTTAttributedLabel

class ChatSessionViewController: UIViewController, UITextViewDelegate, UITableViewDataSource, UITableViewDelegate, SINClientDelegate, SINMessageClientDelegate, UIPopoverPresentationControllerDelegate, MediaPickerDelegate, CLImageEditorDelegate, TTTAttributedLabelDelegate {

    @IBOutlet weak var chatOptionsButton: FeedActionButton!
    
    @IBAction func chatOptionsButtonTouchUpInside(sender: UIButton) {
        let chatOptionsVC = ChatOptionsViewController.getStoryboardInstance()
        
        chatOptionsVC.delegate              = self
        chatOptionsVC.chatSession           = self.chatSession
        chatOptionsVC.isCreator             = self.isCreator
        chatOptionsVC.transitioningDelegate = self.fadeInTransition
        chatOptionsVC.referringButton       = sender
        
        self.presentViewController(chatOptionsVC, animated: true, completion: nil)
    }

    var chatSessionId               : String? = nil
    var chatName                    : String? = nil
    var initializeUserIds           : [Int]? = nil
    var parentView                  : UIView? = nil
    var branchViewDelegate          : BranchViewDelegate? = nil    
    
    let downloadOperations = DownloadContentOperations()
    
    private var sinch_client        : SINClient? = nil
    private var chatSession         : ChatSession? = nil
    private var chatMessages        : [ChatMessage] = []
    private var lastSentMessage     : ChatMessage? = nil
    
    // keep track of self
    private var selfUserId          : Int = 0
    private var isCreator           : Bool = false
    private var currentInitId       : Int? = nil
    private var doNotDisconnectChat : Bool = false
    private var isShowingMediaPicker: Bool = false
    private var contentItemExtension: TreemContentService.ContentFileExtensions?
    
    private var loadingMaskViewController           = LoadingMaskViewController.getStoryboardInstance()
    private let loadingMaskOverlayViewController    = LoadingMaskViewController.getStoryboardInstance()
    
    private let fadeInTransition = FadeInAnimatedTransition()
    
    @IBOutlet weak var chatTableView: UITableView!
    
    @IBOutlet weak var sendChatView: UIView!
    @IBOutlet weak var sendChatViewBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var chatMessageTextView: UITextView!
    @IBOutlet weak var sendChatButton: UIButton!
    
    @IBOutlet weak var divider: UIView!
    @IBOutlet weak var dividerVertLeft: UIView!
    @IBOutlet weak var dividerVertRight: UIView!
    
    // --------------------------------- //
    //# Mark: Initializers / Overrides
    // --------------------------------- //
    
    static func getStoryboardInstance() -> ChatSessionViewController {
        return UIStoryboard(name: "ChatSession", bundle: nil).instantiateInitialViewController() as! ChatSessionViewController
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // update branch title
        self.branchViewDelegate?.setTemporaryTitle?(self.chatName)
        
        // wire up the delegates
        self.chatTableView.delegate = self
        self.chatTableView.dataSource = self
        
        self.chatMessageTextView.delegate = self
        self.chatMessageTextView.textContainer.lineFragmentPadding = 0
        self.chatMessageTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10)
        
        self.divider.backgroundColor            = AppStyles.dividerFormColor
        self.dividerVertRight.backgroundColor   = AppStyles.dividerFormColor
        self.dividerVertLeft.backgroundColor    = AppStyles.dividerFormColor

        self.chatOptionsButton.tintColor        = AppStyles.sharedInstance.midGrayColor

        AppStyles.sharedInstance.setButtonDefaultStyles(self.sendChatButton)
        AppStyles.sharedInstance.setButtonEnabledAndAjustStyles(self.sendChatButton, enabled: false)
        
        self.chatTableView.sectionIndexColor        = AppStyles.sharedInstance.tintColor
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(self.dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        
        self.chatTableView.addGestureRecognizer(tapGesture)
        
        if(self.initializeUserIds != nil){
            self.showLoadingMask()
            self.connectNextUser()
        }
        else{
            self.loadChatSession(false)
        }
        
        NSUserDefaults.standardUserDefaults().setValue(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)
        
        // add observers for showing/hiding keyboard
        let notifCenter = NSNotificationCenter.defaultCenter()
        notifCenter.addObserver(self, selector: #selector(ChatSessionViewController.keyboardWillChangeFrame(_:)), name:UIKeyboardWillChangeFrameNotification, object: nil)
        notifCenter.addObserver(self, selector: #selector(ChatSessionViewController.keyboardDidShow(_:)), name:UIKeyboardDidShowNotification, object: nil)
    }
    
    override func viewDidDisappear(animated: Bool) {
        super.viewDidDisappear(animated)
        
        // remove observers
        let notifCenter = NSNotificationCenter.defaultCenter()
        notifCenter.removeObserver(self, name: UIKeyboardWillChangeFrameNotification, object: nil)
        notifCenter.removeObserver(self, name: UIKeyboardDidShowNotification, object: nil)
        
        if(!self.doNotDisconnectChat){
            self.disconnectFromChatService()
        }
        else{
            self.doNotDisconnectChat = false
        }
    }
    
    override func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        
        // dismiss presented post options view if feed view gone
        if self.isShowingMediaPicker {
            self.dismissViewControllerAnimated(false, completion: nil)
            self.isShowingMediaPicker = false
        }
    }
    
    // --------------------------------- //
    //# Mark: Service Calls
    // --------------------------------- //
    
    private func loadChatSession(maskAlreadyShown: Bool){

        if let sessionId = self.chatSessionId {
            if(maskAlreadyShown == false) {
                self.showLoadingMask()
            }
            
            // get view size
            TreemChatService.sharedInstance.getChatSession(
                CurrentTreeSettings.sharedInstance.treeSession
                , sessionId: sessionId
                , success: {
                    data in
                    
                    self.cancelLoadingMask({
                        
                        self.chatSession = ChatSession(json: data)
                        self.setSelfUserProperties()
                        
                        // we're good to fire up the chat service now
                        if(self.selfUserId > 0){
                            
                            // set the chat history
                            if let history = self.chatSession!.history {
                                self.chatMessages = history
                                self.rebindTableView()
                            }
                            
                            self.connectToChatService()
                        }
                    })
                    
                }
                , failure: {
                    error, wasHandled in
                    
                    self.cancelLoadingMask()
                }
            )
        }
        else{
            // in theory this should never happen
            CustomAlertViews.showGeneralErrorAlertView(self, willDismiss: nil)
        }
    }
    
    
    private func uploadContentItem(contentItemUpload: ContentItemUpload){
        
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0)) {
            
            self.showLoadingMask(true)
            
            let contentType = contentItemUpload.contentType
            
            let contentUploadManager = TreemContentServiceUploadManager(
                treeSession         : CurrentTreeSettings.sharedInstance.treeSession,
                contentItemUpload   : contentItemUpload,
                success : {
                    (data) in
                    
                    self.cancelLoadingMask({
                        var contentItem: ContentItemDownload
                        
                        if contentType == .Video {
                            contentItem = ContentItemDownload(videoObj: ContentItemDownloadVideo(data: data))
                        }
                        else if contentType == .Image {
                            contentItem = ContentItemDownload(imageObj: ContentItemDownloadImage(data: data))
                        }
                        else {
                            contentItem = ContentItemDownload(data: data)
                        }
                        
                        // put a chat message together
                        let requestObj = ChatMessage.init()
                        requestObj.sessionId = self.chatSessionId!
                        requestObj.messageStringId = NSUUID().UUIDString        // sinch will send the same message twice with different ids so we need to keep track our selves...
                        requestObj.userId = self.selfUserId
                        requestObj.messageDate = NSDate()
                        requestObj.contentItem = contentItem
                        requestObj.calculateCellLayoutInfo()
                        
                        // send the chat
                        self.sendChatMessage(requestObj)
                        
                        self.chatMessages.append(requestObj)
                        self.insertBottomTableViewRow()
                    })
                    
                },
                failure : {
                    (error, wasHandled) in
                    
                    self.cancelLoadingMask({
                        // unsupported content type
                        if error == TreemServiceResponseCode.GenericResponseCode2 {
                            self.showUnsupportedTypeAlert()
                        }
                            // attachment too large
                        else if error == TreemServiceResponseCode.GenericResponseCode3 {
                            CustomAlertViews.showCustomAlertView(title: "File too large", message: "Maximum upload size is " + String(TreemContentServiceUploadManager.maxContentGigaBytes) + " gb.")
                        }
                        else if !wasHandled {
                            CustomAlertViews.showGeneralErrorAlertView(self, willDismiss: nil)
                        }
                    })
                    
                },
                progress : {
                    // TODO: show progress bar over upload item
                    (percentComplete, wasCancelled) in
                    
                    self.loadingMaskViewController.updateProgress(percentComplete)
                },
                multiStarted: nil
            )
            
            contentUploadManager.startUpload()
        }
    }

    
    // --------------------------------- //
    //# Mark: Keyboard Events
    // --------------------------------- //

    // handle moving elements when keyboard is pulled up
    func keyboardWillChangeFrame(notification: NSNotification){
        KeyboardHelper.adjustViewAboveKeyboard(notification, currentView: self.view, constraint: self.sendChatViewBottomConstraint, layoutUpdateView: self.parentView ?? self.view, completion: nil)
    }
    
    // scroll to bottom once keyboard is set to show
    func keyboardDidShow(notification: NSNotification) {
        self.scrollToBottom()
    }
    
    // --------------------------------- //
    //# Mark: Private Functions
    // --------------------------------- //
    
    private func showLoadingMask(maskActionView: Bool=false, completion: (() -> Void)?=nil) {
        dispatch_async(dispatch_get_main_queue()) {
            // if we're masking the send chat view it means we're uploading, show the progress mask instead
            if(maskActionView){
                var viewToMask = self.view
                if (self.parentView != nil) { viewToMask = self.parentView! }
                self.loadingMaskViewController.queueProgressMask(viewToMask, showCompletion: completion)
            }
            else{
                let vc : UIView = self.view
                self.loadingMaskViewController.queueLoadingMask(vc, loadingViewAlpha: 1.0, showCompletion: completion)
            }
        }
    }
    
    private func cancelLoadingMask(completion: (() -> Void)? = nil) {
        dispatch_async(dispatch_get_main_queue()) {
            self.loadingMaskViewController.cancelLoadingMask({
                self.loadingMaskOverlayViewController.cancelLoadingMask(completion)
            })
        }
    }
    
    // keep track of who we are
    private func setSelfUserProperties(){
        if let session = self.chatSession{
            
            if let users = session.users {
                for (userId, userObj) in users {
                    if(userObj.isCurrentUser){
                        self.selfUserId = userId
                    }
                }
            }
            
            if let creatorId = session.creatorId {
                if(creatorId == self.selfUserId){
                    self.isCreator = true
                }
            }
        }
    }
    
    private func getChatUser(userId: Int) -> User? {
        if let session = self.chatSession, users = session.users, userObj = users[userId] {
            return userObj
        }
        
        return nil
    }
    
    private func rebindTableView(){
        self.chatTableView.reloadData()
        self.scrollToBottom()
    }
    
    private func insertBottomTableViewRow(){
        self.chatTableView.beginUpdates()
        self.chatTableView.insertRowsAtIndexPaths([NSIndexPath(forRow: self.chatMessages.count-1, inSection: 0)], withRowAnimation: .Automatic)
        self.chatTableView.endUpdates()
        self.scrollToBottom()
    }
    
    private func scrollToBottom(){
        // scroll to the bottom of the view
        if(self.chatMessages.count > 0){
            let indxPth = NSIndexPath(forRow: self.chatMessages.count - 1, inSection: 0)
            self.chatTableView.scrollToRowAtIndexPath(indxPth, atScrollPosition: UITableViewScrollPosition.Bottom, animated: true)
        }
    }
    
    private func backToMainChatList(){
        self.navigationController?.popToRootViewControllerAnimated(true)
        
        self.branchViewDelegate?.setDefaultTitle?()
        self.branchViewDelegate?.toggleBackButton(false, onTouchUpInside: nil)
    }
    
    private func showUnsupportedTypeAlert() {
        var typesList = ""
        
        for type in TreemContentService.ContentFileExtensions.cases {
            typesList += "-" + type
        }
        
        CustomAlertViews.showCustomAlertView(title: "Unsupported type"
            , message: "Image/video uploaded is not a supported type. Supported types include:" + typesList
            , fromViewController: self
            , willDismiss: nil)
    }
    
    // --------------------------------- //
    //# Mark: Form Events
    // --------------------------------- //
    
    @IBAction func attachementButtonTouchUpInside(sender: UIButton) {
        
        let mediaPicker = MediaAddOptionsViewController.getStoryboardInstance()
        
        mediaPicker.delegate                = self
        mediaPicker.transitioningDelegate   = self.fadeInTransition
        mediaPicker.referringButton         = sender
        
        self.isShowingMediaPicker = true
        
        self.presentViewController(mediaPicker, animated: true, completion: nil)
    }
    
    @IBAction func sendButtonTouchUpInside(sender: AnyObject) {
        
        // this will activate the auto correct on the last word if needed
        self.chatMessageTextView.text = self.chatMessageTextView.text + " "
        
        let requestObj = ChatMessage.init()
        requestObj.sessionId = self.chatSessionId!
        requestObj.messageStringId = NSUUID().UUIDString        // sinch will send the same message twice with different ids so we need to keep track our selves...
        requestObj.userId = self.selfUserId
        requestObj.messageText = self.chatMessageTextView.text.trim()
        requestObj.messageDate = NSDate()
        requestObj.calculateCellLayoutInfo()
        
        // send the chat
        self.sendChatMessage(requestObj)
        
        self.chatMessageTextView.text = ""
        AppStyles.sharedInstance.setButtonEnabledAndAjustStyles(self.sendChatButton, enabled: false, withAnimation: true, showDisabledOutline: true)
        self.sendChatButton.layoutIfNeeded()
        
        self.chatMessages.append(requestObj)
        self.insertBottomTableViewRow()
        
        self.dismissKeyboard()
    }
    
    // --------------------------------- //
    //# Mark: Sinch Private Methods
    // --------------------------------- //

    private func connectNextUser(){
        
        self.currentInitId = nil
        
        if let initIds = self.initializeUserIds{
        
            if initIds.count > 0 {
                self.currentInitId = initIds[0]
                
                #if DEBUG
                    print("Connecting Next User: " + currentInitId!.description)
                #endif
                
                self.connectToChatService()
            }
            else{
                
                #if DEBUG
                    print("Initialization Complete")
                #endif
                
                self.loadChatSession(true)
            }
        }
    }
    
    private func connectToChatService(){
        self.sinch_client = Sinch.clientWithApplicationKey(
            Encryption.sharedInstance.getObfuscatedKey(AppSettings.sinch_application_key),
            applicationSecret: Encryption.sharedInstance.getObfuscatedKey(AppSettings.sinch_application_secret),
            environmentHost: AppSettings.sinch_environment_host,
            userId: self.getChatSessionUserId(self.currentInitId ?? self.selfUserId)
        )
        
        if let client = self.sinch_client {
            
            client.setSupportMessaging(true)
            client.start()
            
            client.delegate = self
            client.messageClient().delegate = self
            client.startListeningOnActiveConnection()
        }
    }
    
    private func disconnectFromChatService(){
        // disconnect from change client when we leave
        #if DEBUG
            print("Disconnect from Chat Client")
        #endif
        
        self.killChatClient()
    }
    
    private func killChatClient(){
        // kill the client
        self.sinch_client?.stopListeningOnActiveConnection()
        self.sinch_client?.terminateGracefully()
        self.sinch_client = nil
    }
    
    private func getChatSessionUserId(userId: Int) -> String{
        if let sessionId = self.chatSessionId {
            return sessionId + "|" + userId.description
        }
        return ""
    }
    
    private func getChatRecipients() -> [Int:[String]]? {
        var recipients: [Int:[String]]? = [:]
        var batch : Int = 0
        let maxBatch : Int = 8      // Sinch limits a max of 10 recipients per send so we'll batch tham at 8
        
        recipients![batch] = []
        
        if let session = self.chatSession{
            if let activeIds = session.activeUsers {
                for (userId) in activeIds{
                    if(userId != self.selfUserId){
                        if (recipients![batch]!.count >= maxBatch){
                            batch += 1
                            recipients![batch] = []
                        }
                        recipients![batch]!.append(self.getChatSessionUserId(userId))
                    }
                }
            }
        }
        
        if(recipients![0]!.count < 1){
            recipients = nil
        }
        
        return recipients
    }
    
    private func sendChatMessage(msgObj: ChatMessage) -> Bool{
        var sent = false
        
        // if there isn't anyone else in the chat, do send it yet
        if let chatRecipients = self.getChatRecipients() {
            if let client = self.sinch_client {
                let requstJsonStr = msgObj.toString()
                
                self.lastSentMessage = msgObj
                
                sent = true
                for key in chatRecipients.keys{
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0)) {
                        #if DEBUG
                            print("sending message: " + requstJsonStr + " for batch: " + key.description)
                        #endif
                        client.messageClient().sendMessage(SINOutgoingMessage.init(recipients: chatRecipients[key], text: requstJsonStr))
                    }
                }
            }
        }
        
        return sent
    }
    
    private func makeSelfChatRequestObject(messageType: ChatMessage.MessageType, doLayoutCalc: Bool) -> ChatMessage
    {
        // send a "disconnect" message to all members
        let requestObj = ChatMessage.init()
        requestObj.sessionId = self.chatSessionId!
        requestObj.messageStringId = NSUUID().UUIDString        // sinch will send the same message twice with different ids so we need to keep track our selves...
        requestObj.userId = self.selfUserId
        requestObj.messageDate = NSDate()
        requestObj.messageType = messageType
        
        // only need this if we intend on adding this message back to the screen
        if(doLayoutCalc){
            requestObj.calculateCellLayoutInfo()
        }
        
        return requestObj
    }
    
    // --------------------------------- //
    //# Mark: Sinch Delegates
    // --------------------------------- //
    func clientDidStart(client: SINClient!) {
        #if DEBUG
            print("Chat Client Connected")
        #endif
        
        if let cInitId = self.currentInitId {
            self.disconnectFromChatService()
            if let initUserIds = self.initializeUserIds {
                if let index = initUserIds.indexOf(cInitId){
                    self.initializeUserIds!.removeAtIndex(index)
                    self.connectNextUser()
                }
            }
        }
    }
    
    func clientDidFail(client: SINClient!, error: NSError!) {
        #if DEBUG
            print("Chat Client Failed to Conenct: " + error.description)
        #endif
    }
    
    func messageClient(messageClient: SINMessageClient!, didReceiveIncomingMessage message: SINMessage!) {
        #if DEBUG
            if let msg = message {
                print("Chat Received, Chat ID: " + msg.senderId + ", Details: " + msg.text)
            }
        #endif
        
        if let msg = message{

                let chatMsg = ChatMessage.init(request_string: msg.text)
            
                let searchChats = self.chatMessages.filter({ $0.messageStringId == chatMsg.messageStringId})
            
                if (searchChats.count < 1) {
                    if(chatMsg.sessionId != nil){
                    
                    if(chatMsg.messageType == ChatMessage.MessageType.End){
                        
                        CustomAlertViews.showCustomAlertView(
                            title: "Chat Ended"
                            , message: "This chat has ended"
                            , fromViewController: self
                            , willDismiss: {
                                self.backToMainChatList()
                        })
                    }
                    else if (chatMsg.messageType == ChatMessage.MessageType.Remove){
                        if let session = self.chatSession {
                            if let activeIds = session.activeUsers{
                                if let index = activeIds.indexOf(chatMsg.userId){
                                    self.chatSession!.activeUsers!.removeAtIndex(index)
                                }
                            }
                        }
                    }
                    
                    // only show messages of type chat for now (eventually we'll show messages when people connect, disconnect, etc)
                    self.chatMessages.append(chatMsg)
                    self.insertBottomTableViewRow()
                    
                    // tell our servers this message was received
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0)) {
                        let auditMsg = ChatMessage()
                        auditMsg.messageStringId = chatMsg.messageStringId
                        auditMsg.messageDate = chatMsg.messageDate
                        
                        TreemChatService.sharedInstance.setChatHistoryAudit(
                            CurrentTreeSettings.sharedInstance.treeSession
                            , chatMessage: auditMsg
                            , success: {
                                data in
                                // do nothing
                            }
                            , failure: {
                                error, wasHandled in
                                // do nothing
                            }
                        )
                    }
                }
            }
            else{
                #if DEBUG
                    print("DUPLICATE: duplicate message found from sinch... ")
                #endif
            }
        }
    }
    
    func messageSent(message: SINMessage!, recipientId: String!) {
        #if DEBUG
            var recipIds    : String = ""
            
            for recipId in message.recipientIds {
                recipIds += (recipIds == "") ? "" : ", "
                recipIds += (recipId as! String)
            }
            
            print("Message Id: " + message.messageId + " was sent to: " + recipIds)
        #endif
        
        // update our servers with this chat message
        if let msg = self.lastSentMessage {
            
            if(msg.messageType == nil){
                msg.messageType = ChatMessage.MessageType.Text
            }
            
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0)) {
                TreemChatService.sharedInstance.setChatHistory(
                    CurrentTreeSettings.sharedInstance.treeSession
                    , sessionId: self.chatSessionId!
                    , chatMessage: msg
                    , success: {
                        data in
                        
                        // kill the chat client if we are disconnecting
                        if(msg.messageType == ChatMessage.MessageType.Disconnect){
                            self.killChatClient()
                        }

                    }
                    , failure: {
                        error, wasHandled in
                        
                        if(msg.messageType == ChatMessage.MessageType.Disconnect){
                            self.killChatClient()
                        }
                        
                    }
                )
            }
            self.lastSentMessage = nil
        }
        
    }
    
    func messageDelivered(info: SINMessageDeliveryInfo!) {
        #if DEBUG

            print("Message Id: " + info.messageId + " was delivered to: " + info.recipientId)
        #endif
    }
    func messageFailed(message: SINMessage!, info messageFailureInfo: SINMessageFailureInfo!) {
        #if DEBUG
            print("Message Id: " + message.messageId + " failed. Error: " + messageFailureInfo.error.description)
        #endif
    }
    
    
    // --------------------------------- //
    //# Mark: TableView Delegate Handlers
    // --------------------------------- //
    
    
    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.chatMessages.count
    }
    
    func tableView(tableView: UITableView, heightForRowAtIndexPath indexPath: NSIndexPath) -> CGFloat {
        if(self.chatMessages.indices.contains(indexPath.row)){
            return self.chatMessages[indexPath.row].cellHeightLayout
        }

        return 0
    }
    
    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        var message         : ChatMessage
        var user            : User?         = nil
        var isCurrentUser   : Bool          = false
        
        // get data for both cell types
        if self.chatMessages.indices.contains(indexPath.row) {
            // message is common between
            message = self.chatMessages[indexPath.row]
            
            if let tempUser = self.getChatUser(message.userId) {
                user = tempUser
                
                isCurrentUser = (tempUser.id == self.selfUserId)
            }
        }
        else {
            // no data, return empty cell
            return tableView.dequeueReusableCellWithIdentifier("ChatSessionOtherMemberCell") as! ChatSessionOtherMemberTableViewCell
        }
        
        // load cell for current user
        if isCurrentUser {
            let cell = tableView.dequeueReusableCellWithIdentifier("ChatSessionCurrentMemberCell") as! ChatSessionCurrentMemberTableViewCell
            
            cell.tag = indexPath.row
            
            self.loadChatCellAvatar(user, cell: cell, indexPath: indexPath, avatar: cell.avatar)
            self.loadChatCellDate(message.messageDate, dateLabel: cell.dateLabel)
            self.loadChatCellMessage(message, messageView: cell.messageView, currentUser: true, messageViewWidthConstraint: cell.messageViewWidthConstraint, messageViewHeightConstraint: cell.messageViewHeightConstraint, cell: cell, indexPath: indexPath)
            self.loadChatCellName(user, nameLabel: cell.nameLabel)
            
            return cell
        }
        
        // load cell for other user (either other user or system message)
        let cell = tableView.dequeueReusableCellWithIdentifier("ChatSessionOtherMemberCell") as! ChatSessionOtherMemberTableViewCell

        cell.tag = indexPath.row
        
        self.loadChatCellAvatar(user, cell: cell, indexPath: indexPath, avatar: cell.avatar)
        self.loadChatCellDate(message.messageDate, dateLabel: cell.dateLabel)
        self.loadChatCellMessage(message, messageView: cell.messageView, currentUser: false, messageViewWidthConstraint: cell.messageViewWidthConstraint, messageViewHeightConstraint: cell.messageViewHeightConstraint, cell: cell, indexPath: indexPath)
        self.loadChatCellName(user, nameLabel: cell.nameLabel)

        return cell
    }
    
    // load the chat avatar
    private func loadChatCellAvatar(user: User?, cell: UITableViewCell, indexPath: NSIndexPath, avatar: UIImageView) {
        // load avatar if available
        if let user = user, avatarURL = user.avatar, downloader = DownloadContentOperation(url: avatarURL, cacheKey: user.avatarId) {
            
            downloader.completionBlock = {
                if let image = downloader.image where !downloader.cancelled {
                    // perform UI changes back on the main thread
                    dispatch_async(dispatch_get_main_queue(), {

                        // check that the cell hasn't been reused
                        if (cell.tag == indexPath.row) {

                            // if cell in view then animate, otherwise add if in table but not visible
                            if self.chatTableView.visibleCells.contains(cell) {
                                UIView.transitionWithView(
                                    avatar,
                                    duration: 0.1,
                                    options: UIViewAnimationOptions.TransitionCrossDissolve,
                                    animations: {
                                        avatar.image = image
                                    },
                                    completion: nil
                                )
                            }
                            else {
                                avatar.image = image
                            }
                        }
                    })
                }
            }
            
            self.downloadOperations.startDownload(indexPath, downloadContentOperation: downloader)
            
            avatar.tag = user.id
            avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(ChatSessionViewController.profileTouchUpInside(_:))))
        }
    }
    
    // load the chat message date
    private func loadChatCellDate(date: NSDate?, dateLabel: UILabel) {
        dateLabel.text = date?.getRelativeShorthandDateFormattedString()
    }
    
    // load the chat message into the message view
    private func loadChatCellMessage(message: ChatMessage, messageView: UIView, currentUser: Bool, messageViewWidthConstraint: NSLayoutConstraint, messageViewHeightConstraint: NSLayoutConstraint, cell: UITableViewCell, indexPath: NSIndexPath) {
        // make sure the message view is empty
        for view in messageView.subviews{ view.removeFromSuperview() }

        // message background color depends on current branch
        let messageBackgroundColor  = currentUser ? CurrentTreeSettings.sharedInstance.treeSession.currentBranch?.color ?? AppStyles.sharedInstance.tintColor : AppStyles.sharedInstance.lightGrayColor
        
        // if plain text message
        if let msgText = message.messageText {
            let chatLabel = CopyableLabel()

            chatLabel.delegate = self
        
            // message from another user
            if((message.messageType == ChatMessage.MessageType.Text) || (message.messageType == nil)) {
                messageView.backgroundColor = messageBackgroundColor
                chatLabel.textColor         = currentUser ? AppStyles.sharedInstance.whiteColor : AppStyles.sharedInstance.darkGrayColor
            }
                // system message
            else {
                messageView.backgroundColor = UIColor.clearColor()
                chatLabel.textColor         = AppStyles.sharedInstance.disabledButtonTitleGray
            }
            
            AppStyles.sharedInstance.setURLAttributedLabelStyling(chatLabel, lightBackground: !currentUser)

            chatLabel.font                      = message.cellMsgLabelFont
            chatLabel.lineBreakMode             = .ByWordWrapping
            chatLabel.numberOfLines             = 0
            chatLabel.textAlignment             = .Left
            chatLabel.text                      = msgText
            
            // update chat frame to fit contents
            chatLabel.frame = CGRect(
                x       : message.cellMsgLabelPadding,
                y       : message.cellMsgLabelPadding,
                width   : message.cellMessageTextSize.width,
                height  : message.cellMessageTextSize.height
            )

            messageView.addSubview(chatLabel)
            
            messageViewWidthConstraint.constant     = message.cellMessageViewSize.width
            messageViewHeightConstraint.constant    = message.cellMessageViewSize.height
        }
        // else if image or other media added
        else if let cItem = message.contentItem as? ContentItemDownload {
            messageView.backgroundColor = messageBackgroundColor

            let chatImage = UIImageView()
            
            chatImage.contentMode = .ScaleAspectFit
            
            // update chat frame to fit contents
            chatImage.frame = CGRect(
                x       : message.cellMsgLabelPadding,
                y       : message.cellMsgLabelPadding,
                width   : message.cellMessageImageSize.width,
                height  : message.cellMessageImageSize.height
            )

            // add a tap handler to open the chat image
            chatImage.userInteractionEnabled = true
            
            chatImage.addGestureRecognizer(MediaTapGestureRecognizer(
                target      : self,
                action      : #selector(ChatSessionViewController.chatImageTap(_:)),
                contentURL  : cItem.contentURL,
                contentURLId: cItem.contentURLId,
                contentID   : cItem.contentID,
                contentType : cItem.contentType,
                contentOwner: false
            ))

            messageView.addSubview(chatImage)
            
            messageViewWidthConstraint.constant     = message.cellMessageViewSize.width
            messageViewHeightConstraint.constant    = message.cellMessageViewSize.height
            
            // load chat content item
            if let imgUrl = cItem.contentURL, downloader = DownloadContentOperation(url: imgUrl, cacheKey: cItem.contentURLId) {
                downloader.completionBlock = {
                    // if image downloaded
                    if let image = downloader.image where !downloader.cancelled {
                        // perform UI changes back on the main thread
                        dispatch_async(dispatch_get_main_queue(), {

                            // check that the cell hasn't been reused
                            if (cell.tag == indexPath.row) {

                                // if cell in view then animate, otherwise add if in table but not visible
                                if self.chatTableView.visibleCells.contains(cell) {
                                    UIView.transitionWithView(
                                        chatImage,
                                        duration: 0.1,
                                        options: UIViewAnimationOptions.TransitionCrossDissolve,
                                        animations: {
                                            chatImage.image = image
                                        },
                                        completion: nil
                                    )
                                }
                                else {
                                    chatImage.image = image
                                }
                            }
                        })
                    }
                }
                
                self.downloadOperations.startDownload(indexPath, downloadContentOperation: downloader)
            }
        }
    }
    
    private func loadChatCellName(user: User?, nameLabel: UILabel) {
        if let user = user {
            nameLabel.text  = user.getFullName()
            nameLabel.tag   = user.id
            
            nameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(ChatSessionViewController.profileTouchUpInside(_:))))
        }
    }
    
    func tableView(tableView: UITableView, didEndDisplayingCell cell: UITableViewCell, forRowAtIndexPath indexPath: NSIndexPath) {
        // check if cell at indexpath no longer visible
        if tableView.indexPathsForVisibleRows?.indexOf(indexPath) == nil {
            
            #if DEBUG
                print("Cancel content loading for row: \(indexPath.row)")
            #endif
            
            // cancel the current download operations in the cell
            self.downloadOperations.cancelDownloads(indexPath)
        }
    }
    
    // --------------------------------- //
    //# Mark: Table View Handlers
    // --------------------------------- //
    
    func profileTouchUpInside(sender: UITapGestureRecognizer) {
        if let tag = sender.view?.tag {
            
            // don't disconnect
            self.doNotDisconnectChat = true
            
            // assume current user
            if tag == self.selfUserId {
                let vc = ProfileViewController.getStoryboardInstance()
                
                vc.isPresenting             = true
                
                self.presentViewController(vc, animated: true, completion: nil)
            }
            else {
                let vc = MemberProfileViewController.getStoryboardInstance()
                
                // only one user can be send to the profile page
                vc.userId = tag
                vc.friendChangeCallback = nil
                self.presentViewController(vc, animated: true, completion: nil)
            }
        }
    }

    // --------------------------------- //
    //# Mark: Form Element Handlers
    // --------------------------------- //
    
    func chatSessionBackTouchUpInside(sender: UIButton){
        self.backToMainChatList()
    }
    
    func adaptivePresentationStyleForPresentationController(controller: UIPresentationController) -> UIModalPresentationStyle {
        return .None
    }
    
    func textViewDidChange(textView: UITextView) {
        let enabled = (textView.text ?? "").trim().characters.count > 0
        
        AppStyles.sharedInstance.setButtonEnabledAndAjustStyles(self.sendChatButton, enabled: enabled, withAnimation: true, showDisabledOutline: true)
        
        self.sendChatButton.layoutIfNeeded()
    }

    func chatImageTap(sender: MediaTapGestureRecognizer) {
        if let cType = sender.contentType {
            
            // popovers won't disconnect by default but presenting a whole new view will and we don't want to
            self.doNotDisconnectChat = true
            
            if(cType == .Video) {
                let vc = MediaVideoViewController.getStoryboardInstance()
                
                vc.contentId                = sender.contentID
                vc.contentOwner             = sender.contentOwner
                
                self.presentViewController(vc, animated: true, completion: nil)
            }
            else {
                let vc = MediaImageViewController.getStoryboardInstance()

                vc.contentUrl   = sender.contentURL
                vc.contentId    = sender.contentID
                
                self.presentViewController(vc, animated: true, completion: nil)
            }
        }
    }
    
    // --------------------------------- //
    //# Mark: Options Menu Handlers
    // --------------------------------- //

    func optionsParticipants() {
        if let session = self.chatSession {
            if let activeIds = session.activeUsers {
                let popover = MembersListPopoverViewController.getStoryboardInstance()
                
                var activeUserArray: [User] = []
                
                for (userId) in activeIds{
                    if let user = session.users?[userId] {
                        activeUserArray.append(user)
                    }
                }
                popover.users = activeUserArray
                
                let sender = self.chatOptionsButton
                
                if let popoverMenuView = popover.popoverPresentationController {
                    popoverMenuView.permittedArrowDirections    = .Up
                    popoverMenuView.delegate                    = self
                    popoverMenuView.sourceView                  = sender
                    popoverMenuView.sourceRect                  = CGRect(x: sender.bounds.width * 0.5, y: sender.bounds.height * 0.5, width: 0, height: 0)
                    popoverMenuView.backgroundColor             = UIColor.whiteColor()
                    
                    popover.modalPresentationCapturesStatusBarAppearance = true
                    
                    self.presentViewController(popover, animated: true, completion: nil)
                }
            }
        }
    }
    
    func optionsEndChat() {
        if let sessionId = self.chatSessionId where self.isCreator {
            self.showLoadingMask()
            
            TreemChatService.sharedInstance.endChatSession(
                CurrentTreeSettings.sharedInstance.treeSession
                , sessionId: sessionId
                , success: {
                    data in
                    
                    // send a "end" message to all members
                    let requestObj = self.makeSelfChatRequestObject(ChatMessage.MessageType.End, doLayoutCalc: false)
                    
                    // send the chat
                    self.sendChatMessage(requestObj)
                    
                    self.cancelLoadingMask({
                        self.backToMainChatList()                            
                    })
                    
                }
                , failure: {
                    error, wasHandled in
                    
                    self.cancelLoadingMask()
                }
            )
        }
    }
    
    func optionsLeaveChat() {
        if let sessionId = self.chatSessionId where !self.isCreator {
            self.showLoadingMask()

            TreemChatService.sharedInstance.leaveChat(
                CurrentTreeSettings.sharedInstance.treeSession
                , sessionId: sessionId
                , success: {
                    data in
                    
                    // send a "end" message to all members
                    let requestObj = self.makeSelfChatRequestObject(ChatMessage.MessageType.Remove, doLayoutCalc: false)
                    
                    // send the chat
                    self.sendChatMessage(requestObj)
                    
                    self.cancelLoadingMask({
                        self.backToMainChatList()
                    })
                    
                }
                , failure: {
                    error, wasHandled in
                    
                    self.cancelLoadingMask()
                }
            )
        }
    }
    
    // --------------------------------- //
    //# Mark: Media Picker Delegate Functions
    // --------------------------------- //
    
    func cancelSelected() {
        self.dismissViewControllerAnimated(true, completion: nil)
    }
    
    func imageSelected(image: UIImage, fileExtension: TreemContentService.ContentFileExtensions, picker: UIImagePickerController) {
        
        self.contentItemExtension = fileExtension
        
            
        let imageEditor = ImageEditor(image: image.rotateCameraImageToOrientation(image, maxResolution: AppSettings.max_post_image_resolution), delegate:  self)
        
        self.dismissViewControllerAnimated(true, completion: {
            self.doNotDisconnectChat = true
            self.isShowingMediaPicker = false
            self.presentViewController(imageEditor, animated: true, completion: nil)
        })
    }
    
    func videoSelected(fileURL: NSURL, orientation: ContentItemOrientation, fileExtension: TreemContentService.ContentFileExtensions, picker: UIImagePickerController) {

        let itemUpload = ContentItemUpload(fileExtension: fileExtension, fileURL: fileURL)
        itemUpload.contentType = .Video
        itemUpload.orientation = orientation
        
        self.uploadContentItem(itemUpload)

        self.dismissViewControllerAnimated(true, completion: nil)
    }
    
    func imageEditor(editor: CLImageEditor!, didFinishEdittingWithImage image: UIImage!){
        
        let tempImage = image.rotateCameraImageToOrientation(image, maxResolution: AppSettings.max_post_image_resolution)
        
        if let contentItem = ContentItemUploadImage(fileExtension: self.contentItemExtension!, image: tempImage) {
        
            self.uploadContentItem(contentItem)
        }
        
        self.dismissViewControllerAnimated(false, completion: nil)
    }
    
    // clear open keyboards on tap
    func dismissKeyboard() {
        self.view.endEditing(true)
        self.chatMessageTextView.resignFirstResponder()
    }
    
    //# MARK: Attributed Label Delegate Functions
    func attributedLabel(label: TTTAttributedLabel, didSelectLinkWithURL url: NSURL!) {
        self.showWebBrowser(url.absoluteString)
    }
    
    private func showWebBrowser(url: String, defaultTitle: String? = nil) {
        let vc = WebBrowserViewController.getStoryboardInstance()
        
        vc.webUrl           = url
        vc.defaultTitle     = defaultTitle
        vc.branchColor      = CurrentTreeSettings.sharedInstance.treeSession.currentBranch?.color ?? AppStyles.sharedInstance.darkGrayColor
        vc.isPrivateMode    = CurrentTreeSettings.sharedInstance.currentTree == TreeType.Public
        vc.transitioningDelegate = AppStyles.directionUpViewAnimatedTransition
        
        self.presentViewController(vc, animated: true, completion: nil)
    }
}
