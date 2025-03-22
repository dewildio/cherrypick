import SwiftUI

@main
struct CherryPickApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

struct ContentView: View {
    @State private var selectedPath: String?
    @State private var viewKey = UUID()
    
    var body: some View {
        NavigationView {
            SidebarView(selectedPath: $selectedPath)
            if let path = selectedPath {
                ImageGridView(folderPath: path)
                    .id(viewKey)
            } else {
                Text("Select a folder to view images")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onChange(of: selectedPath) { oldValue, newValue in
            viewKey = UUID()
        }
    }
}
