//
//  ConversationModel.swift
//  HuggingChat-Mac
//
//  Created by Cyril Zakka on 8/29/24.
//

import SwiftUI
import Combine

enum ConversationState: Equatable {
    case none, empty, loaded, loading, generating, error
}

@Observable final class ConversationViewModel {
    
    var isInteracting = false
    var isMultimodal: Bool = false
    var isTools: Bool = false
    var model: AnyObject?
    var message: MessageRow? = nil
    var messages: [MessageRow] = [
//        MessageRow(
//            type: .user,
//            isInteracting: false,
//            contentType: .rawText("What is the meaning of life?")
//        ),
//        MessageRow(
//            type: .assistant,
//            isInteracting: false,
//            contentType: .rawText("""
//### How to Sort a List in Python
//
//1. **Sort a List of Numbers:**
//   ```python
//   numbers = [5, 2, 9, 1, 3]
//   numbers.sort()
//   print(numbers)
//""")
//        ),
    ]
    var error: HFError?
    
    // Tools
    var imageURL: String?
    
    // Context
    var contextAppName: String?
    var contextAppSelectedText: String?
    var contextAppFullText: String?
    var contextAppIcon: NSImage?
    var contextIsSupported: Bool = false
    
    // Currently the best way to get @AppStorage value while returning observability
    var useWebService: Bool {
        get {
            access(keyPath: \.useWebService)
            return UserDefaults.standard.bool(forKey: "useWebSearch")
        }
        set {
            withMutation(keyPath: \.useWebService) {
                UserDefaults.standard.setValue(newValue, forKey: "useWebSearch")
            }
        }
    }
    
    var useContext: Bool {
        get {
            access(keyPath: \.useContext)
            return UserDefaults.standard.bool(forKey: "useContext")
        }
        set {
            withMutation(keyPath: \.useContext) {
                UserDefaults.standard.setValue(newValue, forKey: "useContext")
            }
        }
    }
    
    var externalModel: String {
        get {
            access(keyPath: \.externalModel)
            return UserDefaults.standard.string(forKey: "externalModel") ?? "meta-llama/Meta-Llama-3.1-70B-Instruct"
        }
        set {
            withMutation(keyPath: \.externalModel) {
                UserDefaults.standard.setValue(newValue, forKey: "externalModel")
            }
        }
    }

    private var cancellables = [AnyCancellable]()
    private var sendPromptHandler: SendPromptHandler?
    
    private(set) var conversation: Conversation? {
        didSet {
            guard let conversation = conversation else { return }
            HuggingChatSession.shared.currentConversation = conversation.serverId
        }
    }
    
    var state: ConversationState = .none
    
    func loadConversation(_ conversation: Conversation) {
        self.conversation = conversation
        HuggingChatSession.shared.currentConversation = conversation.serverId
        loadHistory()
    }
    
    private func loadHistory() {
        guard let conversation = conversation else { return }
        state = .loading
        
        NetworkService.getConversation(id: conversation.serverId)
            .receive(on: DispatchQueue.main)
            .map { [weak self] (conversation: Conversation) -> [MessageRow] in
                guard let self else { return [] }
                self.conversation = conversation
                return self.buildHistory(conversation: conversation)
            }
            .sink { completion in
                switch completion {
                case .finished: break
                case .failure(let error):
                    print("Error loading conversation: \(error.localizedDescription)")
                }
            } receiveValue: { [weak self] messages in
                self?.messages = messages
//                self?.internalDelegate?.reloadData()
//                self?.internalDelegate?.scrollToBottom(animated: false)
                self?.state = .loaded
            }.store(in: &cancellables)
    }
    
    private func createConversationAndSendPrompt(_ prompt: String, withFiles: [String]? = nil, usingTools: [String]? = nil) {
        if let model = model as? LLMModel {
            createConversation(with: model, prompt: prompt, withFiles: withFiles, usingTools: usingTools)
        }
    }
    
    private func createConversation(with model: LLMModel, prompt: String, withFiles: [String]? = nil, usingTools: [String]? = nil) {
        state = .loaded
        NetworkService.createConversation(base: model)
            .receive(on: DispatchQueue.main).sink { completion in
                switch completion {
                case .finished:
                    print("ConversationViewModel.createConversation finished")
                case .failure(let error):
                    print("ConversationViewModel.createConversation failed:\n\(error)")
                    self.state = .error
                    self.error = .verbose("Something's wrong. Check your internet connection and try again.")
                }
            } receiveValue: { [weak self] conversation in
                print("Recieved")
                self?.conversation = conversation
                self?.sendAttributed(text: prompt, withFiles: withFiles)
            }.store(in: &cancellables)
    }
    
    func sendAttributed(text: String, withFiles: [String]? = nil) {
        guard let conversation = conversation, let previousId = conversation.messages.last?.id else {
            createConversationAndSendPrompt(text, withFiles: withFiles, usingTools: isTools ? []:nil)
            return
        }
        var trimmedText = ""
        if useContext {
            if let contextAppSelectedText = contextAppSelectedText {
                trimmedText += "Selected Text: ```\(contextAppSelectedText)```"
            }
            if let contextAppFullText = contextAppFullText {
                // TODO: Truncate full context if needed
                trimmedText += "\n\nFull Text:```\(contextAppFullText)```"
            }
        }
        
        trimmedText += text.trimmingCharacters(in: .whitespaces)
        
        // TODO: Add files here
        let userMessage = MessageRow(type: .user, isInteracting: false, contentType: .rawText(trimmedText))
        messages.append(userMessage)
        
        let req = PromptRequestBody(id: previousId, inputs: trimmedText, webSearch: useWebService, files: withFiles, tools: isTools ?  ["000000000000000000000001", "000000000000000000000002", "00000000000000000000000a"] : nil)
        sendPromptRequest(req: req, conversationID: conversation.serverId)
    }
    
    func sendTranscript(text: String) {
        guard let conversation = conversation, let previousId = conversation.messages.last?.id else {
            createConversationAndSendPrompt(text, withFiles: nil, usingTools: nil)
            return
        }
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        let req = PromptRequestBody(id: previousId, inputs: trimmedText, webSearch: useWebService, files: nil, tools: nil)
        sendPromptRequest(req: req, conversationID: conversation.serverId)
    }
    
    private func sendPromptRequest(req: PromptRequestBody, conversationID: String) {
        state = .generating
        isInteracting = true
        imageURL = nil
        let sendPromptHandler = SendPromptHandler(conversationId: conversationID)
        self.sendPromptHandler = sendPromptHandler
        let messageRow = sendPromptHandler.messageRow
        messages.append(messageRow)
        
        let pub = sendPromptHandler.update
            .receive(on: RunLoop.main).eraseToAnyPublisher()

        pub.scan((0, messageRow)) { (tuple, newMessage) in
            (tuple.0 + 1, newMessage)
        }.eraseToAnyPublisher()
            .sink { [weak self] completion in
                guard let self else { return }
                switch completion {
                case .finished:
                    self.sendPromptHandler = nil
                    isInteracting = false
                    self.sendPromptHandler = nil
                    state = .loaded
                case .failure(let error):
                    switch error {
                    case .httpTooManyRequest:
                        self.messages.removeLast(2)
                        self.state = .error
                        self.error = .verbose("You've sent too many requests. Please try logging in before sending a message.")
                        print(error.localizedDescription)
                    default:
                        self.state = .error
                        self.error = error
                        print(error.localizedDescription)
                    }
                }
            } receiveValue: { [weak self] obj in
                guard let self else { return }
                let (count, messageRow) = obj
                
                if count == 1 {
                    self.updateConversation(conversationID: conversationID)
                }
                
                self.message = messageRow
                print(messageRow)
                if let lastIndex = self.messages.lastIndex(where: { $0.id == messageRow.id }) {
                    self.messages[lastIndex] = messageRow
                }

                if let fileInfo = self.message?.fileInfo,
                   fileInfo.mime.hasPrefix("image/"),
                   let conversationID = self.conversation?.id {
                    self.imageURL = "https://huggingface.co/chat/conversation/\(conversationID)/output/\(fileInfo.sha)"
                }
                
            }.store(in: &cancellables)

        sendPromptHandler.sendPromptReq(reqBody: req)
    }
    
    private func updateConversation(conversationID: String) {
        NetworkService.getConversation(id: conversationID).sink { completion in
            switch completion {
            case .finished:
                print("ConversationViewModel.updateConversation finished")
            case .failure(let error):
                self.state = .error
                self.error = .verbose("Uh oh, something's not right! Please check your connection and try again later.")
                print(error.localizedDescription)
            }
        } receiveValue: { [weak self] conversation in
            self?.conversation = conversation
        }.store(in: &cancellables)
    }
    
    func getActiveModel() {
        DataService.shared.getActiveModel().receive(on: DispatchQueue.main).sink { completion in
            switch completion {
            case .finished:
                print("ConversationViewModel.getActiveModel finished")
            case .failure(let error):
                self.state = .error
                self.error = .verbose("Hmm, that didn't go as planned. Please check your connection and try again.")
                print("ConversationViewModel.getActiveModel failed:\n \(error)")
            }
        } receiveValue: { [weak self] model in
            self?.model = model
            self?.externalModel = (model as! LLMModel).name
            self?.isMultimodal = (model as! LLMModel).multimodal
            self?.isTools = (model as! LLMModel).tools
            
        }.store(in: &cancellables)
    }
    
    private func buildHistory(conversation: Conversation) -> [MessageRow] {
        let messages = conversation.messages.compactMap({ (message: Message) -> MessageRow? in
           return MessageRow(message: message)
        })
//        let historyParser = HistoryParser(isDarkMode: isDarkMode)
//        messages = historyParser.parseMessages(messages: messages)
        return messages
    }
    
    func reset() {
        state = .empty
        getActiveModel()
        cancellables = []
        conversation = nil
        error = nil
        isInteracting = false
        HuggingChatSession.shared.currentConversation = ""
        clearContext()
    }
    
    func stopGenerating() {
        cancellables = []
        sendPromptHandler?.cancel()
        completeInteration()
    }
    
    private func completeInteration() {
        isInteracting = false
        sendPromptHandler = nil
        state = .loaded
        error = nil
    }
    
    // MARK: Context Functions
    func fetchContext() {
        self.contextAppName = nil
        self.contextAppSelectedText = nil
        self.contextAppFullText = nil
        self.contextAppIcon = nil
        self.contextIsSupported = false
        Task {
            if let content = await AccessibilityContentReader.shared.getActiveEditorContent() {
                await MainActor.run {
                    self.contextIsSupported = content.isSupported
                    self.contextAppName = content.applicationName
                    self.contextAppIcon = content.applicationIcon
                    if self.contextIsSupported {
                        self.contextAppSelectedText = content.selectedText
                        self.contextAppFullText = content.fullText
                    }
                }
            }
        }
    }
    
    func formatContext() {
        // TODO: Truncate contextAppFullText from start to 3000 characters.
        
    }
    
    func clearContext() {
        contextAppName = nil
        contextAppSelectedText = nil
        contextAppFullText = nil
    }
    
}
