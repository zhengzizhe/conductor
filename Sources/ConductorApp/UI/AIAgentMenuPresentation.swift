import SwiftUI

enum AIAgentMenuPresentation {
    static func sessionTitle(for agent: LaunchableAgent) -> String {
        L("新建%@会话", agent.title)
    }

    static func menuSystemImage(for agent: LaunchableAgent) -> String {
        agent.fallbackSystemImage
    }
}

struct LaunchableAgentIcon: View {
    let agent: LaunchableAgent
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let logo = CLIToolLogo.image(named: agent.logo) {
                if CLIToolLogo.isMonochrome(agent.logo) {
                    Image(nsImage: logo)
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(AppStyle.textSecondary)
                } else {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
            } else {
                Image(systemName: agent.fallbackSystemImage)
                    .font(.system(size: size - 1, weight: .medium))
                    .foregroundStyle(AppStyle.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}
