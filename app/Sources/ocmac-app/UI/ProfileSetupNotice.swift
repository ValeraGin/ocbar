import SwiftUI

struct ProfileSetupNotice: View {
    let state: ProfileSystemState?
    let checking: Bool
    let check: () -> Void

    var body: some View {
        if let state, !state.ready {
            VStack(alignment: .leading, spacing: 8) {
                Label(state.error ?? state.setupMessage,
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Palette.warn)
                if state.needsSetup {
                    Text(L("Выполните команду в Терминале. Для установки скрипта понадобится пароль администратора Mac."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Text("sudo ocmac install").font(.ocMono).textSelection(.enabled)
                        CopyButton(text: "sudo ocmac install")
                    }
                }
                Button(checking ? L("Проверяю…") : L("Проверить готовность"), action: check)
                    .disabled(checking)
            }
        }
    }
}
