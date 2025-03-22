import SwiftUI
import AppKit

struct SidebarView: View {
    @Binding var selectedPath: String?
    @State private var favoriteLocations: [URL] = []
    
    var body: some View {
        List(selection: $selectedPath) {
            Section("Favorites") {
                ForEach(favoriteLocations, id: \.path) { url in
                    HStack {
                        Image(systemName: "folder")
                        Text(url.lastPathComponent)
                    }
                    .tag(url.path)
                }
            }
            
            Button("Select Folder") {
                selectFolder()
            }
            .padding()
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 200, maxWidth: 300)
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                selectedPath = url.path
                if !favoriteLocations.contains(url) {
                    favoriteLocations.append(url)
                }
            }
        }
    }
} 