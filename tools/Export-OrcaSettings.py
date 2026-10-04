"""Export portable Orca preferences without accounts or workspace state."""

import argparse
import json
import os
import sqlite3
from contextlib import closing
from pathlib import Path


# Explicit allowlist: settings also contains credentials, commands and local paths.
SETTING_KEYS = """
worktreeVisibilityDefaults nestWorkspaces refreshLocalBaseRefOnWorktreeCreate
autoRenameBranchFromWork
theme leftSidebarAppearanceMode leftSidebarTintColor leftSidebarTintOpacity
uiLanguage appIcon appFontFamily
editorAutoSave editorAutoSaveDelayMs editorMinimapEnabled editorFontFamily
editorWordWrap richMarkdownSpellcheckEnabled markdownReviewToolsEnabled
primarySelectionMiddleClickPaste
terminalFontSize terminalFontFamily terminalFontWeight terminalFontWeightBold
terminalLineHeight terminalScrollSensitivity terminalFastScrollSensitivity
terminalTuiScrollSensitivity terminalGpuAcceleration terminalLigatures
terminalInlineImages terminalCursorStyle terminalCursorBlink terminalThemeDark
terminalDividerColorDark terminalUseSeparateLightTheme terminalThemeLight
terminalCustomThemes terminalDividerColorLight terminalInactivePaneOpacity
terminalActivePaneOpacity terminalPaneOpacityTransitionMs terminalDividerThicknessPx
terminalRightClickToPaste terminalWindowsShell terminalDefaultShell
terminalWindowsPowerShellImplementation terminalMouseHideWhileTyping
terminalFocusFollowsMouse terminalClipboardOnSelect terminalCopyTrimsGutter
terminalAllowOsc52Clipboard terminalScrollbackRows terminalShortcutPolicy
terminalMacOptionAsAlt terminalJISYenToBackslash
windowBackgroundBlur minimizeToTrayOnClose showMenuBarIcon
openLinksInApp localhostWorktreeLabelsEnabled openLinksInAppModifierInverts
terminalLinkActionPopoverEnabled terminalLinkClickBehavior terminalUrlMiddleClickBehavior
rightSidebarOpenByDefault showGitIgnoredFiles sourceControlViewMode
sourceControlGroupOrder sourceControlCompareAgainstUpstream showTitlebarAppName
showTasksButton showAutomationsButton showArtifactsButton showSkillsButton
showMobileButton showPinnedWorktreesInGroups ctrlTabOrderMode
floatingTerminalEnabled floatingTerminalTriggerLocation
diffDefaultView diffWordWrap diffShowWhitespace diffCollapseUnchangedRegions
combinedDiffFileTreeVisibleByDefault
defaultTuiAgent disabledTuiAgents
tabAutoGenerateTitle confirmClosePinnedTab editorPreviewTabsEnabled
keepComputerAwakeWhileAgentsRun compactWorktreeCards
uiZoomLevel editorFontZoomLevel worktreeCardProperties agentActivityDisplayMode
workspaceStatuses workspaceBoardOpacity workspaceBoardColumnWidth
syncTaskStatusFromWorkspaceBoard statusBarItems statusBarVisible
usagePercentageDisplay statusBarUsageMode browserDefaultZoomLevel
""".split()


def export_settings(database, output):
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
        row = connection.execute(
            "SELECT payload FROM profile_state_documents WHERE domain = ?", ("settings",)
        ).fetchone()
    if row is None:
        raise ValueError("Orca settings domain was not found")
    settings = json.loads(row[0])
    portable = {key: settings[key] for key in SETTING_KEYS if key in settings}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(portable, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return len(portable)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--database", type=Path,
        default=Path(os.environ["APPDATA"]) / "orca/profiles/local-default/profile-state.db",
    )
    parser.add_argument(
        "--output", type=Path,
        default=Path(__file__).resolve().parent.parent / "app-settings/orca/settings.json",
    )
    args = parser.parse_args()
    count = export_settings(args.database, args.output)
    print(f"Exported {count} settings to {args.output}")


if __name__ == "__main__":
    main()
