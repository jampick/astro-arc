import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.UPower
import qs.Commons

// The moving background. When the wallpaper on screen has a depth map (see
// backend/bin/astro-arc-motion), this draws it again on a layer of its own,
// just above Omarchy's background layer, with shaders/parallax.frag shifting
// near things against far ones. Omarchy's still stays underneath the whole
// time, so if anything here fails or is switched off the desktop is the same
// picture, standing still.
//
// What it costs is not the shader (under 0.2 ms a frame at 4K on a desktop
// GPU) but the compositor: every frame damages the whole screen, so Hyprland
// recomposites it and re-blurs anything translucent on top. Hence a low frame
// rate, and pausing whenever nobody can see it or it should not move:
//   - motion is off in the panel, or the wallpaper has no depth map: no layer
//   - Omarchy's no-animations mode (Style.reduceMotion): no layer
//   - on battery: frozen
//   - a fullscreen window on that monitor: frozen
//   - locked or the screen off: Hyprland stops sending frame callbacks to
//     anything under a session lock or on a blanked output, so Qt stops
//     drawing this layer by itself. Only the timer still ticks.
// Frozen keeps the last frame on screen and damages nothing.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginRoot: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.substring(7)
    return u.replace(/\/+$/, "")
  }
  readonly property string motionBin: pluginRoot + "/backend/bin/astro-arc-motion"

  // The speed the user picked from the prototype's ladder: the nearest things
  // peak at about 8 px/s on a 1080-line screen. focusDepth is 0, so the far
  // background stays put and the middle moves at about half that.
  readonly property real parallaxPx: 22
  readonly property real parallaxPeriod: 15
  readonly property int fps: 20
  readonly property int rampMs: 3000

  property bool enabled: false
  property string imagePath: ""
  property string depthPath: ""

  // The bar builds this widget once per monitor, so each copy draws the
  // monitor its own bar is on, and three monitors get three layers, not nine.
  readonly property var hostScreen: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null

  readonly property bool active: enabled && depthPath !== "" && !Style.reduceMotion && hostScreen !== null
  readonly property bool globallyFrozen: UPower.onBattery

  // Settings live in the same file the panel edits; only an explicit true
  // turns motion on, so it is off until someone asks for it.
  FileView {
    path: root.home + "/.local/state/omarchy/settings/astro-arc.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        root.enabled = JSON.parse(text() || "{}").motion === true
      } catch (e) {
        root.enabled = false
      }
    }
    onLoadFailed: root.enabled = false
  }

  function refresh() {
    if (!root.enabled) {
      root.imagePath = ""
      root.depthPath = ""
      return
    }
    if (lookup.running) {
      lookup.again = true
      return
    }
    lookup.running = true
  }

  onEnabledChanged: refresh()

  // Omarchy repoints current/background (a symlink) on every wallpaper or
  // theme change. A directory model is the one watcher here that sees the
  // link being replaced, so it stands in for an inotify watch on the folder.
  FolderListModel {
    folder: "file://" + root.home + "/.local/state/omarchy/current"
    showHidden: true
    showDirs: true
    onStatusChanged: if (status === FolderListModel.Ready) root.refresh()
  }

  Process {
    id: lookup
    property bool again: false
    command: [root.motionBin, "lookup"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = String(text || "").replace(/\n+$/, "").split("\t")
        var image = parts[0] || ""
        var depth = parts.length > 1 ? parts[1] : ""
        // A new path reloads its Image, which drops the layer to transparent
        // until both textures are in, so old and new never mix on screen.
        root.imagePath = image
        root.depthPath = depth
      }
    }
    onExited: {
      if (again) {
        again = false
        running = true
      }
    }
  }

  LazyLoader {
    active: root.active

    PanelWindow {
      id: panel

      screen: root.hostScreen
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      // Bottom, not Background: it has to sit above Omarchy's own background
      // layer, and within one layer the stacking follows creation order,
      // which a monitor being plugged in can shuffle. Nothing else uses
      // Bottom, and windows still stack above it.
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.namespace: "astro-arc-motion"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Clicks fall through to Omarchy's background (its double-click picker).
      mask: Region {}

      readonly property var monitor: Hyprland.monitorFor(root.hostScreen)
      readonly property bool fullscreen: monitor && monitor.activeWorkspace ? monitor.activeWorkspace.hasFullscreen === true : false
      readonly property bool frozen: root.globallyFrozen || fullscreen
      readonly property bool ready: still.status === Image.Ready && depthImage.status === Image.Ready

      readonly property int decodeWidth: width > 0 ? Math.ceil(width * screen.devicePixelRatio) : 0
      readonly property int decodeHeight: height > 0 ? Math.ceil(height * screen.devicePixelRatio) : 0

      // 0 at first, so the opening frame matches the still underneath, then
      // eased up to full so the zoom and the drift arrive together.
      property real strength: 0
      property real time: 0

      NumberAnimation {
        id: ramp
        target: panel
        property: "strength"
        from: 0
        to: 1
        duration: root.rampMs
        easing.type: Easing.InOutSine
      }

      onReadyChanged: {
        if (ready) {
          strength = 0
          ramp.restart()
        } else {
          ramp.stop()
          strength = 0
        }
      }

      Timer {
        interval: Math.round(1000 / root.fps)
        repeat: true
        running: panel.ready && !panel.frozen
        onTriggered: panel.time += interval / 1000
      }

      Image {
        id: still
        visible: false
        // The depth map's name is the image's hash. Carrying it in the URL
        // reloads the still when a theme switch rewrites the same path
        // (current/theme/backgrounds/background.png) with a new picture.
        source: root.imagePath && root.depthPath && panel.decodeWidth > 0
          ? "file://" + root.imagePath + "?" + root.depthPath.split("/").pop() : ""
        sourceSize.width: panel.decodeWidth
        sourceSize.height: panel.decodeHeight
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
      }

      Image {
        id: depthImage
        visible: false
        source: root.depthPath ? "file://" + root.depthPath : ""
        asynchronous: true
        cache: false
        smooth: true
      }

      ShaderEffect {
        anchors.fill: parent
        visible: panel.ready
        fragmentShader: Qt.resolvedUrl("shaders/parallax.frag.qsb")

        property var source: still
        property var depth: depthImage
        property real time: panel.time
        property real screenAspect: panel.width / Math.max(panel.height, 1)
        property real imageAspect: still.implicitWidth / Math.max(still.implicitHeight, 1)
        property real parallaxPx: root.parallaxPx * panel.strength
        property real parallaxPeriod: root.parallaxPeriod
        // Enough zoom that the largest shift never shows an edge: the x reach
        // in full, the y reach at the path's 0.6, plus 2 px for filtering.
        property real overscan: panel.strength * Math.max((0.6 * root.parallaxPx + 2) / 1080,
                                                          (root.parallaxPx + 2) / (1080 * screenAspect))
      }
    }
  }
}
