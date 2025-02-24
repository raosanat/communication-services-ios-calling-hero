//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License.
//

import UIKit
import AVFoundation
import AzureCommunicationCalling

class CallViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    // MARK: Constants

    let updateDelayInterval: TimeInterval = 2.5

    // MARK: Properties

    var joinCallConfig: JoinCallConfig!
    var callingContext: CallingContext!

    private var bottomDrawerViewController: BottomDrawerViewController?

    private let eventHandlingQueue = DispatchQueue(label: "eventHandlingQueue", qos: .userInteractive)
    private var lastParticipantViewsUpdateTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var isParticipantViewsUpdatePending: Bool = false
    private var isParticipantViewsUpdateQueued: Bool = false
    private var isParticipantViewLayoutInvalidated: Bool = false

    private var localParticipantIndexPath: IndexPath?
    private var localParticipantView = LocalParticipantView()
    private var participantIdIndexPathMap: [String: IndexPath] = [:]
    private var participantIndexPathViewMap: [IndexPath: ParticipantView] = [:]

    // MARK: IBOutlets

    @IBOutlet weak var localVideoViewContainer: UIRoundedView!
    @IBOutlet weak var participantsView: UICollectionView!
    @IBOutlet weak var toggleVideoButton: UIButton!
    @IBOutlet weak var toggleMuteButton: UIButton!
    @IBOutlet weak var selectAudioDeviceButton: UIButton!
    @IBOutlet weak var showParticipantsButton: UIButton!
    @IBOutlet weak var infoHeaderView: InfoHeaderView!
    @IBOutlet weak var bottomControlBar: UIStackView!
    @IBOutlet weak var rightControlBar: UIStackView!
    @IBOutlet weak var contentViewBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var contentViewTrailingContraint: NSLayoutConstraint!
    @IBOutlet weak var localVideoViewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var localVideoViewWidthConstraint: NSLayoutConstraint!
    @IBOutlet weak var verticalToggleVideoButton: UIButton!
    @IBOutlet weak var verticalToggleMuteButton: UIButton!
    @IBOutlet weak var verticalSelectAudioDeviceButton: UIButton!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!

    // MARK: UIViewController events

    override func viewDidLoad() {
        super.viewDidLoad()

        participantsView.delegate = self
        participantsView.dataSource = self
        participantsView.contentInsetAdjustmentBehavior = .never

        toggleVideoButton.isSelected = !joinCallConfig.isCameraOn
        toggleMuteButton.isSelected = joinCallConfig.isMicrophoneMuted

        updateToggleVideoButtonState()

        localParticipantView.setOnSwitchCamera { [weak self] in
            guard let self = self else {
                return
            }

            self.localParticipantView.switchCameraButton.isEnabled = false
            self.callingContext.switchCamera { _ in
                self.localParticipantView.switchCameraButton.isEnabled = true
            }
        }

        // Join the call asynchronously so that navigation is not blocked
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }

            self.callingContext.joinCall(self.joinCallConfig) { _ in
                self.onJoinCall()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.navigationController?.setNavigationBarHidden(true, animated: animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        localParticipantView.dispose()
        self.navigationController?.setNavigationBarHidden(false, animated: animated)
        UIApplication.shared.isIdleTimerDisabled = false
        forcePortraitOrientation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Avoid infinite loop of collectionView layout
        if isParticipantViewLayoutInvalidated {
            participantsView.collectionViewLayout.invalidateLayout()
            isParticipantViewLayoutInvalidated = false
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        isParticipantViewLayoutInvalidated = true
        if UIDevice.current.orientation.isLandscape {
            setupLandscapeUI()
        } else {
            setupPortraitUI()
        }
    }

    private func setupLandscapeUI() {
        rightControlBar.isHidden = false
        bottomControlBar.isHidden = true
        contentViewBottomConstraint.constant = 0
        contentViewTrailingContraint.constant = rightControlBar.frame.size.width
        localVideoViewWidthConstraint.constant = 110
        localVideoViewHeightConstraint.constant = 85
        verticalToggleMuteButton.isSelected = toggleMuteButton.isSelected
        verticalToggleVideoButton.isSelected = toggleVideoButton.isSelected
    }

    private func setupPortraitUI() {
        rightControlBar.isHidden = true
        bottomControlBar.isHidden = false
        contentViewBottomConstraint.constant = bottomControlBar.frame.size.height
        contentViewTrailingContraint.constant = 0
        localVideoViewWidthConstraint.constant = 75
        localVideoViewHeightConstraint.constant = 100
        toggleMuteButton.isSelected = verticalToggleMuteButton.isSelected
        toggleVideoButton.isSelected = verticalToggleVideoButton.isSelected
    }

    deinit {
        cleanViewRendering()
    }

    private func openAudioDeviceDrawer() {
        let audioDeviceSelectionDataSource = AudioDeviceSelectionDataSource()
        let bottomDrawerViewController = BottomDrawerViewController(dataSource: audioDeviceSelectionDataSource, allowsSelection: true)
        present(bottomDrawerViewController, animated: false, completion: nil)
    }

    private func openParticipantListDrawer() {
        let participantListDataSource = ParticipantListDataSource(participantsFetcher: getParticipantInfoList)
        bottomDrawerViewController = BottomDrawerViewController(dataSource: participantListDataSource)
        present(bottomDrawerViewController!, animated: false, completion: nil)
    }

    private func getParticipantInfoList() -> [ParticipantInfo] {
        // Show local participant first
        var participantInfoList = [
            ParticipantInfo(
                displayName: callingContext.displayName + " (Me)",
                isMuted: callingContext.isCallMuted ?? false)
        ]
        // Get the rest of remote participants
        participantInfoList.append(contentsOf: callingContext.remoteParticipants.map {
            ParticipantInfo(
                displayName: $0.displayName,
                isMuted: $0.isMuted)
        })
        return participantInfoList
    }

    // MARK: UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return participantIndexPathViewMap.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ParticipantViewCell", for: indexPath)

        if let participantView = participantIndexPathViewMap[indexPath] {
            attach(participantView, to: cell.contentView)
        }

        return cell
    }

    // MARK: UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        switch participantIndexPathViewMap.count {
        case 0...1:
            cellWidth = collectionView.bounds.width
            cellHeight = collectionView.bounds.height
        case 2...4:
            cellWidth = collectionView.bounds.width / 2
            cellHeight = collectionView.bounds.height / 2
        default:
            if UIScreen.main.bounds.width > UIScreen.main.bounds.height {
                cellWidth = collectionView.bounds.width / 3
                cellHeight = collectionView.bounds.height / 2
            } else {
                cellWidth = collectionView.bounds.width / 2
                cellHeight = collectionView.bounds.height / 3
            }
        }
        return CGSize(width: cellWidth, height: cellHeight)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        return UIEdgeInsets.zero
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        return 0
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        return 0
    }

    // MARK: Actions

    @IBAction func onNavBarStop(_ sender: UIBarButtonItem) {
        showConfirmHangupModal()
    }

    private func showConfirmHangupModal() {
        let hangupConfirmationViewController = HangupConfirmationViewController()
        hangupConfirmationViewController.modalPresentationStyle = .overCurrentContext
        hangupConfirmationViewController.delegate = self
        hangupConfirmationViewController.modalTransitionStyle = .crossDissolve
        present(hangupConfirmationViewController, animated: true, completion: nil)
    }

    @IBAction func onShare(_ sender: UIButton) {
        let shareTitle = "Share Group Call ID"
        let shareItems = [JoinIdShareItem(joinId: callingContext.joinId, shareTitle: shareTitle)]
        let activityController = UIActivityViewController(activityItems: shareItems as [Any], applicationActivities: nil)

        // The UIActivityViewController's has non-null popoverPresentationController property when running on iPad
        if let popoverPC = activityController.popoverPresentationController,
           let stackView = sender.superview {
            let convertRect = stackView.convert(sender.frame, to: self.view)
            popoverPC.sourceView = self.view
            popoverPC.sourceRect = convertRect
        }

        self.present(activityController, animated: true, completion: nil)
    }

    @IBAction func onToggleVideo(_ sender: UIButton) {
        sender.isSelected.toggle()
        if sender.isSelected {
            callingContext.stopLocalVideoStream { [weak self] _ in
                guard let self = self else {
                    return
                }
                DispatchQueue.main.async {
                    self.localParticipantView.updateVideoDisplayed(isDisplayVideo: false)
                    self.localParticipantView.dispose()
                    if self.localParticipantIndexPath == nil {
                        self.localVideoViewContainer.isHidden = true
                    }
                }
            }
        } else {
            callingContext.startLocalVideoStream { [weak self] localVideoStream in
                guard let self = self else {
                    return
                }
                DispatchQueue.main.async {
                    guard let localVideoStream = localVideoStream else {
                        self.updateToggleVideoButtonState()
                        return
                    }
                    self.localParticipantView.updateVideoStream(localVideoStream: localVideoStream)
                    self.localParticipantView.updateVideoDisplayed(isDisplayVideo: true)
                    if self.localParticipantIndexPath == nil {
                        self.localVideoViewContainer.isHidden = false
                    }
                }
            }
        }
    }

    @IBAction func onToggleMute(_ sender: UIButton) {
        sender.isSelected.toggle()
        (sender.isSelected ? callingContext.mute : callingContext.unmute) { _ in }
    }

    @IBAction func selectAudioDeviceButtonPressed(_ sender: UIButton) {
        openAudioDeviceDrawer()
    }

    @IBAction func showParticipantsButtonPressed(_ sender: UIButton) {
        openParticipantListDrawer()
    }

    @IBAction func onEndCall(_ sender: UIButton) {
        showConfirmHangupModal()
    }

    @IBAction func contentViewDidTapped(_ sender: UITapGestureRecognizer) {
        infoHeaderView.toggleDisplay()
    }

    private func onJoinCall() {
        NotificationCenter.default.addObserver(self, selector: #selector(onRemoteParticipantsUpdated(_:)), name: .remoteParticipantsUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemoteParticipantViewChanged(_:)), name: .remoteParticipantViewChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onIsMutedChanged(_:)), name: .onIsMutedChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appAssignActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)

        infoHeaderView.toggleDisplay()
        meetingInfoViewUpdate()
        initParticipantViews()
        activityIndicator.stopAnimating()
    }

    private func updateToggleVideoButtonState() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized,
             .notDetermined:
            toggleVideoButton.isEnabled = true
            verticalToggleVideoButton.isEnabled = true
        case .denied,
             .restricted:
            toggleVideoButton.isEnabled = false
            verticalToggleVideoButton.isEnabled = false
        @unknown default:
            print("Need video permission from user")
        }
    }

    private func endCall() {
        callingContext.endCall { _ in
            print("Call Ended")
        }
    }

    private func cleanViewRendering() {
        localParticipantView.dispose()

        for participantView in participantIndexPathViewMap.values {
            participantView.dispose()
        }
    }

    private func forcePortraitOrientation() {
        let value = UIInterfaceOrientation.portrait.rawValue
        UIDevice.current.setValue(value, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }

    private func initParticipantViews() {
        let remoteParticipantsToDisplay = getRemoteParticipantsToDisplay()
        // Remote participants
        for (index, participant) in remoteParticipantsToDisplay.enumerated() {
            let remoteParticipantView = ParticipantView()
            remoteParticipantView.updateDisplayName(displayName: participant.displayName)
            remoteParticipantView.updateMuteIndicator(isMuted: participant.isMuted)
            remoteParticipantView.updateActiveSpeaker(isSpeaking: participant.isSpeaking)

            if let videoStream = participant.videoStreams.first(where: { $0.mediaStreamType == .screenSharing }) {
                remoteParticipantView.updateVideoStream(remoteVideoStream: videoStream, isScreenSharing: true)
            } else {
                remoteParticipantView.updateVideoStream(remoteVideoStream: participant.videoStreams.first)
            }

            let userIdentifier = participant.identifier.stringValue ?? ""
            let indexPath = IndexPath(item: index, section: 0)

            participantIdIndexPathMap[userIdentifier] = indexPath
            participantIndexPathViewMap[indexPath] = remoteParticipantView
        }

        // Local participant
        localParticipantView.updateDisplayName(displayName: callingContext.displayName + " (Me)")
        localParticipantView.updateMuteIndicator(isMuted: joinCallConfig.isMicrophoneMuted)
        localParticipantView.updateVideoDisplayed(isDisplayVideo: callingContext.isCameraPreferredOn)

        if callingContext.isCameraPreferredOn {
            callingContext.withLocalVideoStream { localVideoStream in
                if let localVideoStream = localVideoStream {
                    self.localParticipantView.updateVideoStream(localVideoStream: localVideoStream)
                }
            }
        }

        if participantIndexPathViewMap.count == 1 {
            // Use separate view for local video when only 1 remote participant
            localVideoViewContainer.isHidden = !callingContext.isCameraPreferredOn
            localParticipantView.updateDisplayNameVisible(isDisplayNameVisible: false)
            localParticipantView.updateCameraSwitch(isOneOnOne: true)
            attach(localParticipantView, to: localVideoViewContainer)
        } else {
            // Display Local video in last position of grid
            let indexPath = IndexPath(item: participantIndexPathViewMap.count, section: 0)
            localParticipantIndexPath = indexPath
            participantIndexPathViewMap[indexPath] = localParticipantView
            localParticipantView.updateDisplayNameVisible(isDisplayNameVisible: true)
            localParticipantView.updateCameraSwitch(isOneOnOne: false)
            localVideoViewContainer.isHidden = true
        }

        participantsView.reloadData()
    }

    private func queueParticipantViewsUpdate() {
        eventHandlingQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            if self.isParticipantViewsUpdatePending {
                // Defer next update until the current update is complete
                self.isParticipantViewsUpdateQueued = true
                return
            }

            self.isParticipantViewsUpdatePending = true

            // Default 0 sec delay for updates
            var delaySecs = 0.0

            // For rapid updates, include delay
            let lastUpdateInterval = Date().timeIntervalSince1970 - self.lastParticipantViewsUpdateTimestamp
            if lastUpdateInterval < self.updateDelayInterval {
                delaySecs = self.updateDelayInterval - lastUpdateInterval
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + delaySecs) {
                self.updateParticipantViews(completionHandler: self.onUpdateParticipantViewsComplete)
            }
        }
    }

    private func onUpdateParticipantViewsComplete() {
        eventHandlingQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            self.lastParticipantViewsUpdateTimestamp = Date().timeIntervalSince1970
            self.isParticipantViewsUpdatePending = false

            if self.isParticipantViewsUpdateQueued {
                // Reset queue and run last update
                self.isParticipantViewsUpdateQueued = false
                self.queueParticipantViewsUpdate()
            }
        }
    }

    private func getRemoteParticipantsToDisplay() -> MappedSequence<String, RemoteParticipant> {
        var remoteParticipantsToDisplay: MappedSequence<String, RemoteParticipant>
        if let screenSharingParticipant = callingContext.currentScreenSharingParticipant,
           let userIdentifier = screenSharingParticipant.identifier.stringValue {
            remoteParticipantsToDisplay = MappedSequence<String, RemoteParticipant>()
            remoteParticipantsToDisplay.append(forKey: userIdentifier, value: screenSharingParticipant)
        } else {
            remoteParticipantsToDisplay = callingContext.displayedRemoteParticipants
        }
        return remoteParticipantsToDisplay
    }

    private func updateParticipantViews(completionHandler: @escaping () -> Void) {
        // Previous maps tracking participants
        let prevParticipantIdIndexPathMap = participantIdIndexPathMap
        var prevParticipantIndexPathViewMap = participantIndexPathViewMap

        // New maps to track updated list of participants
        participantIdIndexPathMap = [:]
        participantIndexPathViewMap = [:]

        // Collect IndexPath changes for batch update
        var deleteIndexPaths: [IndexPath] = []
        var indexPathMoves: [(at: IndexPath, to: IndexPath)] = []
        var insertIndexPaths: [IndexPath] = []

        let remoteParticipantsToDisplay = getRemoteParticipantsToDisplay()
        // Build new maps and collect changes
        for (index, participant) in remoteParticipantsToDisplay.enumerated() {
            let userIdentifier = participant.identifier.stringValue ?? ""
            let indexPath = IndexPath(item: index, section: 0)
            var participantView: ParticipantView

            // Check for previously tracked participants
            if let prevIndexPath = prevParticipantIdIndexPathMap[userIdentifier],
               let prevParticipantView = prevParticipantIndexPathViewMap[prevIndexPath] {
                prevParticipantIndexPathViewMap.removeValue(forKey: prevIndexPath)

                participantView = prevParticipantView

                if prevIndexPath != indexPath {
                    // Add to move list
                    indexPathMoves.append((at: prevIndexPath, to: indexPath))
                }
            } else {
                participantView = ParticipantView()

                // Add to insert list
                insertIndexPaths.append(indexPath)
            }

            participantView.updateDisplayName(displayName: participant.displayName)
            participantView.updateMuteIndicator(isMuted: participant.isMuted)
            participantView.updateActiveSpeaker(isSpeaking: participant.isSpeaking)
            if let videoStream = participant.videoStreams.first(where: { $0.mediaStreamType == .screenSharing }) {
                participantView.updateVideoStream(remoteVideoStream: videoStream, isScreenSharing: true)
            } else {
                participantView.updateVideoStream(remoteVideoStream: participant.videoStreams.first)
            }

            participantIdIndexPathMap[userIdentifier] = indexPath
            participantIndexPathViewMap[indexPath] = participantView
        }

        // Do not include local participant in cleanup
        if localParticipantIndexPath != nil {
            prevParticipantIndexPathViewMap.removeValue(forKey: localParticipantIndexPath!)
        }

        // Handle local video
        if participantIndexPathViewMap.count == 1 {
            // Remove local participant from grid when only 1 remote participant
            if localParticipantIndexPath != nil {
                deleteIndexPaths.append(localParticipantIndexPath!)
                localParticipantIndexPath = nil
                detach(localParticipantView)
            }

            localVideoViewContainer.isHidden = !callingContext.isCameraPreferredOn
            localParticipantView.updateDisplayNameVisible(isDisplayNameVisible: false)
            localParticipantView.updateCameraSwitch(isOneOnOne: true)
            attach(localParticipantView, to: localVideoViewContainer)
        } else {
            // Display Local video in last position of grid
            let indexPath = IndexPath(item: participantIndexPathViewMap.count, section: 0)

            if let prevIndexPath = localParticipantIndexPath {
                if prevIndexPath != indexPath {
                    // Move if previously in the grid but wrong position
                    indexPathMoves.append((at: prevIndexPath, to: indexPath))
                }
            } else {
                detach(localParticipantView)

                // Insert new grid item for local video
                insertIndexPaths.append(indexPath)
            }

            localParticipantIndexPath = indexPath
            participantIndexPathViewMap[indexPath] = localParticipantView
            localParticipantView.updateDisplayNameVisible(isDisplayNameVisible: true)
            localParticipantView.updateCameraSwitch(isOneOnOne: false)
            localVideoViewContainer.isHidden = true
        }

        // Clean up removed participants - previously tracked but no longer tracked
        for (key, value) in prevParticipantIndexPathViewMap {
            value.dispose()
            deleteIndexPaths.append(key)
        }

        // Batch updates on UICollectionView
        UIView.performWithoutAnimation {
            participantsView.performBatchUpdates({
                participantsView.deleteItems(at: deleteIndexPaths)

                for move in indexPathMoves {
                    participantsView.moveItem(at: move.at, to: move.to)
                }

                participantsView.insertItems(at: insertIndexPaths)
            }, completion: {_ in
                completionHandler()
            })
        }
    }

    private func attach(_ participantView: ParticipantView, to containerView: UIView) {
        participantView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(participantView)

        let constraints = [
            participantView.topAnchor.constraint(equalTo: containerView.topAnchor),
            participantView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            participantView.leftAnchor.constraint(equalTo: containerView.leftAnchor),
            participantView.rightAnchor.constraint(equalTo: containerView.rightAnchor)
        ]

        NSLayoutConstraint.activate(constraints)
    }

    private func detach(_ participantView: ParticipantView) {
        participantView.removeFromSuperview()
    }

    private func meetingInfoViewUpdate() {
        infoHeaderView.updateParticipant(count: callingContext.participantCount)
    }

    private func participantListUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let bottomDrawerViewController = self.bottomDrawerViewController,
                  bottomDrawerViewController.isViewLoaded else {
                return
            }

            bottomDrawerViewController.refreshBottomDrawer()
        }
    }

    @objc func onRemoteParticipantsUpdated(_ notification: Notification) {
        queueParticipantViewsUpdate()
        participantListUpdate()
        meetingInfoViewUpdate()
    }

    @objc func onRemoteParticipantViewChanged(_ notification: Notification) {
        queueParticipantViewsUpdate()
        participantListUpdate()
    }

    @objc func onIsMutedChanged(_ notification: Notification) {
        if let isCallMuted = callingContext.isCallMuted {
            toggleMuteButton.isSelected = isCallMuted
            verticalToggleMuteButton.isSelected = isCallMuted
            localParticipantView.updateMuteIndicator(isMuted: isCallMuted)
            participantListUpdate()
        }
    }

    @objc func appResignActive(_ notification: Notification) {
        callingContext.pauseLocalVideoStream { _ in }
    }

    @objc func appAssignActive(_ notification: Notification) {
        callingContext.resumeLocalVideoStream { _ in }
    }

    func promptForFeedback() {
        let feedbackViewController = FeedbackViewController()
        feedbackViewController.onDoneBlock = { [weak self] didTapFeedback in
            if !didTapFeedback {
                let sequeId = "UnwindToStart"
                self?.performSegue(withIdentifier: sequeId, sender: nil)
            }
        }
        navigationController?.pushViewController(feedbackViewController, animated: true)
    }
}

extension CallViewController: HangupConfirmationViewControllerDelegate {
    func didConfirmEndCall() {
        endCall()
        promptForFeedback()
        cleanViewRendering()
    }
}
