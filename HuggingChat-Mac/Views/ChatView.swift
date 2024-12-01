//import Models
import UniformTypeIdentifiers
import MarkdownView
import SwiftUI
import PDFKit

struct ChatView: View {
    
    enum FocusedField {
        case localInput
        case serverInput
    }
    
    @Environment(ModelManager.self) private var modelManager
    @Environment(ConversationViewModel.self) private var conversationModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance: Appearance = .auto
    @AppStorage("inlineCodeHiglight") private var inlineCodeHiglight: AccentColorOption = .blue
    @AppStorage("lightCodeBlockTheme") private var lightCodeBlockTheme: String = "xcode"
    @AppStorage("darkCodeBlockTheme") private var darkCodeBlockTheme: String = "monokai-sublime"
    @AppStorage("selectedTheme") private var selectedTheme: String = "Default"
    @AppStorage("localModel") private var selectedLocalModel: String = "None"
    @AppStorage("isLocalGeneration") private var isLocalGeneration: Bool = false
    
    // Theme
    @AppStorage("isAppleClassicUnlocked") var isAppleClassicUnlocked: Bool = false
    @AppStorage("isChromeDinoUnlocked") var isChromeDinoUnlocked: Bool = false
    
    // Animation
    @State var cardIndex: Int = 0
    
    // Text field
    @State private var prompt: String = ""
    @FocusState private var focusedField: FocusedField?
    @State private var isMainTextFieldVisible: Bool = true
    
    @State private var isSecondaryTextFieldVisible: Bool = false
    @State private var animatablePrompt: String = ""
    @State private var startLoadingAnimation: Bool = false
    
    // Chat history handling
    @AppStorage("chatClearInterval") private var chatClearInterval: String = "never"
    @State private var lastChatTime: Date = Date()
    
    // File handling
    @State private var allAttachments: [LLMAttachment] = []
    
    // Error
    @State var errorAttempts: Int = 0
    @State private var errorSize: CGSize = CGSize(width: 0, height: 100)
    
    // Response
    @State private var isResponseVisible: Bool = false
    @State var meshSpeed: CGFloat = 0.4
    @State private var responseSize: CGSize = CGSize(width: 0, height: 320)
    
    // Ripple animation vars
    //    @State var counter: Int = 0
    //    @State var origin: CGPoint = .init(x: 0.5, y: 0.5)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            
            if selectedLocalModel != "None" {
                CardStack([
                    AnyView(localInputView.focused($focusedField, equals: .localInput)), // It physically pains me to do type erasure like this
                    AnyView(serverInputView.focused($focusedField, equals: .serverInput)),
                ], selectedIndex: $cardIndex)
                
            } else {
                serverInputView.focused($focusedField, equals: .serverInput)
            }
            
            // Response View
            if isResponseVisible {
                ResponseView(isResponseVisible: $isResponseVisible, responseSize: $responseSize, isLocal: isLocalGeneration)
            }
            
            
            // Sources
            if let webSearch = conversationModel.message?.webSearch, conversationModel.isInteracting == false {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(webSearch.sources) { source in
                            LinkPreview(link: source)
                                .frame(maxWidth: 160)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            
            // ErrorView
            if conversationModel.state == .error || modelManager.loadState.isError {
                if cardIndex == 0 &&  modelManager.loadState.isError {
                    // Local
                    if selectedLocalModel != "None" {
                        switch modelManager.loadState {
                        case .error(let error):
                            ScrollView {
                                Text(error)
                                    .padding(20)
                                    .onGeometryChange(for: CGRect.self) { proxy in
                                        proxy.frame(in: .global)
                                    } action: { newValue in
                                        errorSize.width = newValue.width
                                        errorSize.height = min(max(newValue.height, 20), 100)
                                    }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            .frame(height: errorSize.height)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        default:
                            EmptyView()
                        }

                    }
                    
                }
                
                if cardIndex == 1 && conversationModel.state == .error {
                    // Server
                    ScrollView {
                        Text(conversationModel.error?.description ?? "")
                            .padding(20)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { newValue in
                                errorSize.width = newValue.width
                                errorSize.height = min(max(newValue.height, 20), 100)
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    .frame(height: errorSize.height)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            }
        }
        .modifier(Shake(animatableData: CGFloat(errorAttempts)))
        .padding()
        .padding(.horizontal, 10) // Allows for shake animation
        
        .onChange(of: conversationModel.state) {
            if conversationModel.state == .error {
                isResponseVisible = false
                prompt = animatablePrompt
                isChromeDinoUnlocked = true
                withAnimation(.default) {
                    self.errorAttempts += 1
                }
            }
        }
        .onChange(of:  modelManager.loadState.isError) {
            if modelManager.loadState.isError {
                isResponseVisible = false
                prompt = animatablePrompt
                isChromeDinoUnlocked = true
                withAnimation(.default) {
                    self.errorAttempts += 1
                }
            }
        }
        
        .preferredColorScheme(colorScheme(for: appearance))
        .onChange(of: cardIndex) {
            if cardIndex == 0 {
                focusedField = .localInput
            } else if cardIndex == 1{
                focusedField = .serverInput
            }
        }
        .onAppear {
            if isLocalGeneration {
                cardIndex = 0
                focusedField = .localInput
            } else {
                cardIndex = 1
                focusedField = .serverInput
            }
            conversationModel.getActiveModel()
            checkAndClearChat()
        }
    }
    
    @ViewBuilder
    private var localInputView: some View {
        
        InputView(
            isLocal: true,
            prompt: $prompt,
            isSecondaryTextFieldVisible: $isSecondaryTextFieldVisible,
            animatablePrompt: $animatablePrompt,
            isMainTextFieldVisible: $isMainTextFieldVisible,
            allAttachments: $allAttachments,
            startLoadingAnimation: $startLoadingAnimation,
            isResponseVisible: $isResponseVisible
        )
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(content: {
            if startLoadingAnimation {
                ZStack {
                    AnimatedMeshGradient(colors: ThemingEngine.shared.currentTheme.animatedMeshMainColors, speed: $meshSpeed)
                        .mask {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(lineWidth: 6.0)
                        }
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        })
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
       
    }
    
    @ViewBuilder
    private var serverInputView: some View {
        InputView(
            prompt: $prompt,
            isSecondaryTextFieldVisible: $isSecondaryTextFieldVisible,
            animatablePrompt: $animatablePrompt,
            isMainTextFieldVisible: $isMainTextFieldVisible,
            allAttachments: $allAttachments,
            startLoadingAnimation: $startLoadingAnimation,
            isResponseVisible: $isResponseVisible
        )
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(content: {
            if startLoadingAnimation {
                ZStack {
                    AnimatedMeshGradient(colors: ThemingEngine.shared.currentTheme.animatedMeshMainColors, speed: $meshSpeed)
                        .mask {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(lineWidth: 6.0)
                        }
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        })
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private func colorScheme(for appearance: Appearance) -> ColorScheme? {
        switch appearance {
        case .light:
            return .light
        case .dark:
            return .dark
        case .auto:
            return nil
        }
    }

    private func checkAndClearChat() {
        let currentTime = Date()
        let timeInterval = currentTime.timeIntervalSince(lastChatTime)
        
        switch chatClearInterval {
        case "15min":
            if timeInterval >= 15 * 60 {
                clearChat()
            }
        case "1hour":
            if timeInterval >= 60 * 60 {
                clearChat()
            }
        case "1day":
            if timeInterval >= 24 * 60 * 60 {
                clearChat()
            }
        case "never":
            // Do nothing
            break
        default:
            // Handle unexpected values
            print("Unexpected chat clear interval: \(chatClearInterval)")
        }
    }
    
    private func clearChat() {
        allAttachments.removeAll()
        conversationModel.stopGenerating()
        conversationModel.reset()
        modelManager.clearText()
        isResponseVisible = false
        conversationModel.message = nil
        prompt = ""
        animatablePrompt = ""
    }
}


#Preview("dark") {
    ChatView()
        .frame(height: 300)
        .environment(ModelManager())
        .environment(ConversationViewModel())
        .colorScheme(.dark)
}
