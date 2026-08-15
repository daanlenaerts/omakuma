import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "daan.uptime-kuma"
  ipcTarget: "daan.uptime-kuma"

  // The bar and its popup can intentionally use opposite contrast schemes.
  // Keep their text roles separate instead of carrying the bar foreground
  // onto the popup surface.
  readonly property color barForeground: bar ? bar.barForeground : Color.bar.text
  readonly property color foreground: Color.popups.text
  readonly property color panelBackground: Color.popups.background
  readonly property bool lightTheme: (panelBackground.r * 0.299 + panelBackground.g * 0.587 + panelBackground.b * 0.114) > 0.55
  // Qt.darker() only produces a secondary tone on dark themes. Blend toward
  // the theme's muted role instead, which stays subordinate while retaining
  // readable contrast on both light and dark popup surfaces.
  readonly property color dim: Qt.rgba(
    foreground.r * 0.45 + Color.muted.r * 0.55,
    foreground.g * 0.45 + Color.muted.g * 0.55,
    foreground.b * 0.45 + Color.muted.b * 0.55,
    foreground.a)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Resolved from this file's own location so the plugin works wherever it is
  // installed — a clone, a symlink to a dev checkout, or the shipped path.
  readonly property string pluginDir: {
    var dir = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return dir.replace(/\/$/, "")
  }
  readonly property string stateCommand: pluginDir + "/state.sh"
  readonly property string saveCommand: pluginDir + "/save-config.sh"
  readonly property string themeColorsPath: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml"

  // Theme accents, refreshed from the active theme's colors.toml.
  property color upColor: Color.accent
  property color pendingColor: Color.accent

  // The Uptime Kuma mark, verbatim upstream art, recoloured at render time:
  // the bar's own foreground while healthy, so it sits with the rest of the
  // bar, and the semantic alert red the moment something is wrong.
  readonly property string logoSource: pluginDir + "/assets/uptime-kuma-mark.svg"
  readonly property bool hasIssue: configured && (!ok || down > 0)
  // A semantic red, not the theme's urgent colour: themes can tint "red"
  // toward their own palette (daan-forest uses olive), while an outage must
  // remain unmistakably red. Use variants with enough contrast for the
  // current popup surface.
  readonly property color alertColor: lightTheme ? "#b42318" : "#ff6b6b"

  // Nerd Font glyphs, verified against the shell's font.
  readonly property string glyphSetup: String.fromCodePoint(0xF013)
  readonly property string glyphUp: String.fromCodePoint(0xF05E0)
  readonly property string glyphDown: String.fromCodePoint(0xF0159)
  readonly property string glyphPending: String.fromCodePoint(0xF0150)
  readonly property string glyphMaintenance: String.fromCodePoint(0xF0AD)
  readonly property string glyphLink: String.fromCodePoint(0xF0339)
  readonly property string glyphKey: String.fromCodePoint(0xF0306)
  readonly property string glyphSave: String.fromCodePoint(0xF00C)
  readonly property string glyphCancel: String.fromCodePoint(0xF00D)

  property var state: ({
    ok: false,
    error: "",
    dashboard: "",
    config: ({ url: "", hasKey: false, insecure: false, path: "" }),
    configured: false,
    monitors: [],
    total: 0,
    up: 0,
    down: 0,
    pending: 0,
    maintenance: 0
  })
  property bool refreshing: false
  property string lastUpdated: ""

  readonly property bool ok: state && state.ok === true
  readonly property bool configured: state && state.configured === true
  readonly property var config: (state && state.config) ? state.config : ({})
  readonly property int total: Number(state.total || 0)
  readonly property int up: Number(state.up || 0)
  readonly property int down: Number(state.down || 0)
  readonly property int pending: Number(state.pending || 0)
  readonly property int maintenance: Number(state.maintenance || 0)
  readonly property string dashboard: String(state.dashboard || "")
  readonly property var monitors: state && Array.isArray(state.monitors) ? state.monitors : []
  readonly property int refreshInterval: Math.max(5, Number(root.setting("interval", 30))) * 1000

  // Setup form state. `setupOpen` is the user asking for it; an unconfigured
  // instance shows the form regardless, so a fresh install lands on setup.
  property bool setupOpen: false
  property string formUrl: ""
  property string formKey: ""
  property bool formInsecure: false
  property string formError: ""
  property bool saving: false
  readonly property bool showSetup: setupOpen || !configured

  readonly property color statusColor: {
    if (!configured) return pendingColor
    if (hasIssue) return alertColor
    if (pending > 0) return pendingColor
    return barForeground
  }

  // "Down count only": the bare mark while everything is healthy.
  readonly property string barCount: (configured && ok && down > 0) ? String(down) : ""

  readonly property string tooltip: {
    if (!configured) return "Uptime Kuma · click to set up"
    if (!ok) return "Uptime Kuma · " + (String(state.error || "unavailable"))
    var parts = [up + " up"]
    if (down > 0) parts.push(down + " down")
    if (pending > 0) parts.push(pending + " pending")
    if (maintenance > 0) parts.push(maintenance + " in maintenance")
    if (lastUpdated !== "") parts.push("checked " + lastUpdated)
    return "Uptime Kuma · " + parts.join(" · ")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function parseState(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && typeof parsed === "object") {
        state = parsed
        lastUpdated = Qt.formatTime(new Date(), "HH:mm")
      }
    } catch (e) {
      console.warn("daan.uptime-kuma: invalid state output", e)
    }
  }

  function refresh() {
    if (stateProcess.running) return
    refreshing = true
    stateProcess.running = true
  }

  function loadThemeColors(raw) {
    var lines = String(raw || "").split("\n")
    var found = {}
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*(green|yellow)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) found[match[1]] = match[2]
    }
    upColor = found["green"] || Color.accent
    pendingColor = found["yellow"] || Color.accent
  }

  // The bar documents a shellQuote() helper but does not actually expose one,
  // so quote here. Single quotes with the '\'' escape are safe for any URL.
  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function openDashboard() {
    if (!bar || dashboard === "") return
    bar.run("xdg-open " + shellQuote(dashboard))
    close()
  }

  // Prefill from the stored config. The API key is never handed back to us, so
  // the field starts empty and an empty submit keeps whatever is on disk.
  function openSetup() {
    formUrl = String(config.url || "")
    formKey = ""
    formInsecure = config.insecure === true
    formError = ""
    setupOpen = true
    Qt.callLater(function () { urlField.forceActiveFocus() })
  }

  function cancelSetup() {
    if (!configured) return close()
    setupOpen = false
    formError = ""
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function saveSetup() {
    if (saving) return
    var url = formUrl.trim()
    if (url === "") {
      formError = "The instance URL is required"
      return
    }
    if (!/^https?:\/\//.test(url)) {
      formError = "The URL must start with http:// or https://"
      return
    }

    formError = ""
    saving = true
    saveProcess.payload = JSON.stringify({ url: url, apiKey: formKey, insecure: formInsecure })
    saveProcess.running = true
  }

  function statusGlyph(status) {
    if (status === "up") return glyphUp
    if (status === "down") return glyphDown
    if (status === "pending") return glyphPending
    if (status === "maintenance") return glyphMaintenance
    return "?"
  }

  function statusColorFor(status, fallback) {
    if (status === "up") return upColor
    if (status === "down") return alertColor
    if (status === "pending") return pendingColor
    if (status === "maintenance") return dim
    return fallback
  }

  function statusLabel(monitor) {
    var status = String(monitor.status || "unknown")
    if (status === "up" && monitor.responseTime !== null && monitor.responseTime !== undefined)
      return monitor.responseTime + " ms"
    return status.charAt(0).toUpperCase() + status.slice(1)
  }

  function monitorDetail(monitor) {
    var kind = String(monitor.type || "")
    var target = String(monitor.url || monitor.hostname || "")
    // Monitors with no URL of their own — groups above all, but also ping and
    // push — are reported with a bare scheme. That is noise, not a target.
    if (/^https?:\/\/?$/.test(target)) target = ""
    if (target !== "" && kind !== "") return kind + "  ·  " + target
    return target !== "" ? target : kind
  }

  function heroMeta() {
    if (showSetup) return configured ? "SETTINGS" : "SETUP"
    if (!ok) return "UNAVAILABLE"
    if (down > 0) return down + (down === 1 ? " MONITOR DOWN" : " MONITORS DOWN")
    if (pending > 0) return "DEGRADED"
    if (total === 0) return "NO ACTIVE MONITORS"
    return "ALL SYSTEMS UP"
  }

  // Only the setup form earns a detail pill. The monitor count is already in
  // the MONITORS header and the check time lives in the bar tooltip, so the
  // status views keep the header to one line.
  function heroDetail() {
    if (showSetup) return configured ? "Update the connection" : "Connect your instance"
    return ""
  }

  onOpenedChanged: if (opened) {
    refresh()
    if (monitorFlick) monitorFlick.contentY = 0
    if (!configured) Qt.callLater(function () { root.openSetup() })
    else Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: stateProcess
    command: [root.stateCommand]
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseState(text)
    }

    onExited: function (exitCode) {
      root.refreshing = false
      if (exitCode !== 0) console.warn("daan.uptime-kuma: state command exited", exitCode)
    }
  }

  // Writes the config file. The API key goes over stdin, never argv.
  Process {
    id: saveProcess
    property string payload: ""
    command: [root.saveCommand]
    running: false
    stdinEnabled: true

    onStarted: {
      write(payload + "\n")
      payload = ""
      stdinEnabled = false
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.formError = text.trim()
    }

    onExited: function (exitCode) {
      root.saving = false
      if (exitCode === 0) {
        root.formKey = ""
        root.setupOpen = false
        root.formError = ""
        root.refresh()
        Qt.callLater(function () { keyCatcher.forceActiveFocus() })
      } else if (root.formError === "") {
        root.formError = "Could not save the configuration"
      }
    }
  }

  FileView {
    path: root.themeColorsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadThemeColors(text())
    onFileChanged: reload()
    onLoadFailed: {
      root.upColor = Color.accent
      root.pendingColor = Color.accent
    }
  }

  Timer {
    interval: root.refreshInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The label is replaced by `barContent` below, but `text` still drives the
    // button's own sizing fallback, so keep it in sync with what we draw.
    text: root.barCount
    labelVisible: false
    hasVisualContent: true
    active: !root.configured || root.hasIssue || root.pending > 0
    activeColor: root.statusColor
    fontSize: Style.font.bodySmall
    horizontalMargin: 3.5
    fixedWidth: (root.bar && root.bar.vertical) ? -1 : barContent.implicitWidth + Style.spaceReal(7)
    tooltipText: root.tooltip

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.MiddleButton) root.openDashboard()
      else root.toggle()
    }

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(3)

      KumaMark {
        visible: root.configured
        size: Style.space(15)
        healthyColor: root.barForeground
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: !root.configured
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyphSetup
        color: root.statusColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: root.barCount !== "" && !(root.bar && root.bar.vertical)
        anchors.verticalCenter: parent.verticalCenter
        text: root.barCount
        color: root.statusColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Header and footer are pinned, so the panel asks for their full height
    // plus whatever the scrolling middle wants, and the cap does the rest.
    contentHeight: panel.fittedContentHeight(
      headerColumn.implicitHeight + bodyColumn.implicitHeight + footerColumn.implicitHeight + Style.space(24),
      Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the form is up its fields own the keyboard; Esc and Enter are
      // handled on the fields themselves.
      blocked: root.showSetup
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) {
          monitorFlick.contentY = Math.max(0, Math.min(
            monitorFlick.contentY + dy * Style.space(58),
            Math.max(0, monitorFlick.contentHeight - monitorFlick.height)
          ))
        }
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        if (text === "r" || text === "R") root.refresh()
        else if (text === "o" || text === "O") root.openDashboard()
        else if (text === "s" || text === "S") root.openSetup()
      }

      // ── Pinned header ─────────────────────────────────────────────────

      Column {
        id: headerColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Uptime Kuma"
          meta: root.heroMeta()
          detail: root.heroDetail()
          foreground: root.foreground
          // PanelHero currently derives its secondary tone with Qt.darker().
          // On light themes opacity restores the intended visual hierarchy.
          metaOpacity: root.lightTheme ? 0.72 : 1.0
          fontFamily: root.fontFamily

          iconComponent: Component {
            Item {
              implicitWidth: Style.font.display
              implicitHeight: Style.font.display

              KumaMark {
                visible: !root.showSetup
                anchors.centerIn: parent
                size: parent.implicitWidth
              }

              Text {
                anchors.centerIn: parent
                visible: root.showSetup
                text: root.glyphSetup
                // In the form the icon is chrome, not status — only an
                // unconfigured instance tints it, as a nudge to finish setup.
                color: root.configured ? root.foreground : root.pendingColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          trailingControl: Component {
            PanelActionButton {
              visible: root.configured && !root.showSetup
              iconText: root.glyphSetup
              tooltipText: "Settings"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openSetup()
            }
          }
        }

        PanelSeparator {
          visible: !root.showSetup && root.ok
          foreground: root.foreground
        }

        Column {
          visible: !root.showSetup && root.ok
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "OVERVIEW"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            SummaryCell { label: "Up"; value: root.up; active: root.up > 0; tone: root.upColor }
            SummaryCell { label: "Down"; value: root.down; active: root.down > 0; tone: root.alertColor }
            SummaryCell { label: "Pending"; value: root.pending; active: root.pending > 0; tone: root.pendingColor }
            SummaryCell { label: "Maint"; value: root.maintenance; active: root.maintenance > 0; tone: root.foreground }
          }
        }

        PanelSeparator {
          visible: !root.showSetup && root.ok && root.monitors.length > 0
          foreground: root.foreground
        }

        // Pinned with the overview, so the list scrolls under a stable label.
        PanelSectionHeader {
          width: parent.width
          visible: !root.showSetup && root.ok && root.monitors.length > 0
          text: "MONITORS  ·  " + root.total
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
      }

      // ── Scrolling middle ──────────────────────────────────────────────

      Flickable {
        id: monitorFlick
        anchors.top: headerColumn.bottom
        anchors.bottom: footerColumn.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.space(12)
        anchors.bottomMargin: root.showSetup ? 0 : Style.space(8)
        contentWidth: width
        contentHeight: bodyColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: bodyColumn
          width: monitorFlick.width
          spacing: Style.space(12)

          // ── Setup form ──────────────────────────────────────────────

          Column {
            id: setupColumn
            visible: root.showSetup
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "CONNECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            FieldLabel { glyph: root.glyphLink; label: "Instance URL" }

            TextField {
              id: urlField
              width: parent.width
              placeholderText: "https://kuma.example.com"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              enabled: !root.saving
              text: root.formUrl

              onTextChanged: if (text !== root.formUrl) root.formUrl = text
              onAccepted: keyField.forceActiveFocus()
              Keys.onEscapePressed: root.cancelSetup()
            }

            FieldLabel { glyph: root.glyphKey; label: "API key" }

            TextField {
              id: keyField
              width: parent.width
              password: true
              placeholderText: root.config.hasKey === true ? "•••••••••   leave blank to keep" : "uk1_…"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              enabled: !root.saving
              text: root.formKey

              onTextChanged: if (text !== root.formKey) root.formKey = text
              onAccepted: root.saveSetup()
              Keys.onEscapePressed: root.cancelSetup()
            }

            Text {
              width: parent.width
              text: "Uptime Kuma → Profile → Settings → API Keys → Add API Key"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Toggle {
              width: parent.width
              label: "Allow self-signed certificate"
              description: "Only for instances behind a private CA"
              checked: root.formInsecure
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.formInsecure = !root.formInsecure
            }

            Text {
              width: parent.width
              visible: root.formError !== ""
              text: root.formError
              color: root.alertColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: root.saving ? "Saving…" : "Save & test"
                iconText: root.glyphSave
                bordered: true
                enabled: !root.saving
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                onClicked: root.saveSetup()
              }

              Button {
                text: root.configured ? "Cancel" : "Close"
                iconText: root.glyphCancel
                bordered: true
                enabled: !root.saving
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                onClicked: root.cancelSetup()
              }
            }

            Text {
              width: parent.width
              text: "Stored in " + String(root.config.path || "~/.config/omarchy/uptime-kuma.json").replace(Quickshell.env("HOME") || "", "~")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }

          // ── Error state ─────────────────────────────────────────────

          Column {
            visible: !root.showSetup && !root.ok
            width: parent.width
            spacing: Style.space(12)

            Text {
              width: parent.width
              text: String(root.state.error || "Could not reach Uptime Kuma")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              topPadding: Style.space(16)
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              Button {
                text: "Retry"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                onClicked: root.refresh()
              }

              Button {
                text: "Settings"
                iconText: root.glyphSetup
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                onClicked: root.openSetup()
              }
            }
          }

          // ── Monitors ────────────────────────────────────────────────

          Column {
            visible: !root.showSetup && root.ok && root.monitors.length > 0
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.monitors

              MonitorRow {
                width: parent ? parent.width : 0
                monitor: modelData
                rowIndex: index
              }
            }
          }
        }
      }

      // ── Pinned footer ─────────────────────────────────────────────────

      Column {
        id: footerColumn
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)
        visible: !root.showSetup

        PanelSeparator {
          visible: root.ok && root.monitors.length > 0
          foreground: root.foreground
          strength: 0.07
        }

        Text {
          width: parent.width
          text: "R refresh  ·  O dashboard  ·  S settings  ·  Esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // The upstream mark, recoloured to a flat theme colour the way the bar
  // recolours symbolic tray icons: the art is layered and hidden, and the
  // effect draws it.
  component KumaMark: Item {
    id: kumaMark
    property real size: Style.space(22)
    property color healthyColor: root.foreground

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    Image {
      id: kumaImage
      anchors.fill: parent
      source: root.logoSource
      // Rasterise above the drawn size so the mark stays crisp on scaled
      // outputs and while the bar animates.
      sourceSize.width: Math.round(kumaMark.size * 3)
      sourceSize.height: Math.round(kumaMark.size * 3)
      fillMode: Image.PreserveAspectFit
      smooth: true
      asynchronous: true
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: kumaImage
      source: kumaImage
      colorization: 1.0
      colorizationColor: root.hasIssue ? root.alertColor : kumaMark.healthyColor

      Behavior on colorizationColor {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }
  }

  component FieldLabel: Row {
    id: fieldLabel
    property string glyph: ""
    property string label: ""

    spacing: Style.space(6)

    Text {
      text: fieldLabel.glyph
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      text: fieldLabel.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component SummaryCell: Rectangle {
    id: summaryCell
    property string label: ""
    property int value: 0
    property bool active: false
    property color tone: root.foreground

    width: (parent.width - parent.spacing * 3) / 4
    implicitHeight: summaryLabels.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    // Status cards should keep their semantic hue even when a theme defines
    // the generic selected state as foreground (as daan-forest does).
    color: summaryCell.active
      ? Qt.rgba(summaryCell.tone.r, summaryCell.tone.g, summaryCell.tone.b, root.lightTheme ? 0.14 : 0.22)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.lightTheme ? 0.045 : 0.06)

    Column {
      id: summaryLabels
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: summaryCell.value
        color: summaryCell.active ? summaryCell.tone : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: summaryCell.label.toUpperCase()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  component MonitorRow: Column {
    id: monitorRow
    property var monitor: ({})
    property int rowIndex: 0
    readonly property string status: String(monitorRow.monitor.status || "unknown")

    spacing: Style.space(8)

    PanelSeparator {
      visible: monitorRow.rowIndex > 0
      foreground: root.foreground
      strength: 0.07
    }

    Item {
      width: monitorRow.width
      implicitHeight: Math.max(monitorGlyph.implicitHeight, monitorLabels.implicitHeight, monitorStatus.implicitHeight)

      Text {
        id: monitorGlyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.statusGlyph(monitorRow.status)
        color: root.statusColorFor(monitorRow.status, root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
      }

      Column {
        id: monitorLabels
        anchors.left: monitorGlyph.right
        anchors.leftMargin: Style.space(10)
        anchors.right: monitorStatus.left
        anchors.rightMargin: Style.space(12)
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: String(monitorRow.monitor.name || "Monitor")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: monitorRow.status === "down" || monitorRow.status === "pending"
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: root.monitorDetail(monitorRow.monitor)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        id: monitorStatus
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.statusLabel(monitorRow.monitor)
        color: monitorRow.status === "up" ? root.dim : root.statusColorFor(monitorRow.status, root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: monitorRow.status === "down"
      }
    }
  }
}
