import AIDomain
import SwiftUI

/// 「上传材料」浮层：粘贴 / 导入一篇文字 → 一次请求拆成 情景 + 跟读句 + 生词表（#208）。
struct MaterialUploadSheet: View {

    @Bindable var state: AppState
    var onClose: () -> Void
    @Environment(\.forestTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("把一篇课文 / 文章交给老师，拆成一套能练的东西：一个情景对话、一批跟读句、一张生词表（生词自动收进词汇本）。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    editor

                    HStack(spacing: 10) {
                        Button {
                            importFile()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                                Text("导入 txt / md")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.appPressable)
                        .help("从文件导入材料正文")

                        Spacer(minLength: 0)

                        if let issue = MaterialKitRule.inputIssue(for: state.materialDraft) {
                            Text(issueText(issue))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Button {
                            Task { await state.generateMaterialFromDraft() }
                        } label: {
                            HStack(spacing: 5) {
                                if state.isGeneratingMaterial {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "wand.and.stars").font(.system(size: 10, weight: .bold))
                                }
                                Text(state.isGeneratingMaterial ? "拆解中…" : "生成练习")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(theme.onAccentFill)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(theme.accentFill))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.appPressable)
                        .disabled(state.isGeneratingMaterial || MaterialKitRule.inputIssue(for: state.materialDraft) != nil)
                        .help("一次生成 = 一次模型请求")
                    }

                    if let notice = state.materialResult {
                        resultBanner(notice)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.surfaceAlt)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("上传材料")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("材料 → 情景 + 跟读句 + 生词表")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.hover))
            }
            .buttonStyle(.appPressable)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }

    // MARK: - 输入区

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { state.materialDraft },
                set: { state.materialDraft = $0 }
            ))
            .font(.system(size: 12, design: .rounded))
            .scrollContentBackground(.hidden)
            .foregroundStyle(theme.primaryText)
            .frame(height: 180)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 1)
            )
            .accessibilityLabel("材料正文输入框")

            if state.materialDraft.isEmpty {
                Text("把材料正文粘贴到这里（至少 \(MaterialKitRule.minimumLength) 字）…")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
    }

    private func resultBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.lastGeneratedKit != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(state.lastGeneratedKit != nil ? theme.accent : theme.warning)
            Text(notice)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                state.dismissMaterialResult()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.appPressable)
            .accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
    }

    // MARK: - 零件

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.text]
        panel.message = "选择一篇文字材料（txt / md）"
        if panel.runModal() == .OK, let url = panel.url {
            state.importMaterialFile(at: url.path)
        }
    }

    private func issueText(_ issue: MaterialKitRule.InputIssue) -> String {
        switch issue {
        case .empty:
            "还没有粘贴材料"
        case .tooShort(let actual):
            "材料太短（\(actual)/\(MaterialKitRule.minimumLength) 字）"
        }
    }
}
