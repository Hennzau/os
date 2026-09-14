import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
    id: root

    property int dimSeconds: 30
    property int sleepSeconds: 300
    property int dimPercent: 10
    property int restorePercent: -1

    // Stay awake until told otherwise: Mod+Shift+I toggles this through the
    // "idle" IPC target, and the bar shows "awake" while it is set. Gating the
    // monitors is what stops the dim and the suspend - there is no
    // IdleInhibitor type in Quickshell 0.3.1 to hand the compositor instead.
    property bool inhibited: false

    onInhibitedChanged: {
        if (inhibited)
            root.restore();
    }

    function restore() {
        if (root.restorePercent > 0) {
            root.brightness(root.restorePercent);
            root.restorePercent = -1;
        }
    }

    Process {
        id: runner
    }

    function brightness(percent) {
        runner.command = ["brightnessctl", "set", percent + "%"];
        runner.startDetached();
    }

    Process {
        id: probe

        command: ["brightnessctl", "-m"]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(",");
                if (parts.length < 4)
                    return;

                const current = parseInt(parts[3]);

                root.restorePercent = current;
                root.brightness(root.dimPercent);
            }
        }
    }

    IdleMonitor {
        enabled: !root.inhibited
        timeout: root.dimSeconds

        respectInhibitors: true

        onIsIdleChanged: {
            if (isIdle) {
                probe.running = true;
                return;
            }

            root.restore();
        }
    }

    Process {
        id: sleeper
    }

    IdleMonitor {
        enabled: !root.inhibited
        timeout: root.sleepSeconds
        respectInhibitors: true

        onIsIdleChanged: {
            if (!isIdle)
                return;

            sleeper.command = ["sh", "-c", "elvos-lock & sleep 0.3; systemctl suspend"];
            sleeper.startDetached();
        }
    }
}
