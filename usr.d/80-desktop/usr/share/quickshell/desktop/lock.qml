import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import "theme"

ShellRoot {
    id: root

    property string password: ""
    property string status: ""
    property bool busy: false

    property bool answered: false

    signal clearPassword

    PamContext {
        id: pam

        configDirectory: "/usr/share/quickshell/desktop/pam"
        config: "lock.conf"

        onPamMessage: {
            if (pam.messageIsError && pam.message !== "")
                root.status = pam.message;

            if (!pam.responseRequired)
                return;

            if (root.answered) {
                pam.abort();
                root.busy = false;
                root.answered = false;
                root.password = "";
                root.clearPassword();
                return;
            }

            root.answered = true;
            pam.respond(root.password);
        }

        onCompleted: result => {
            root.busy = false;
            root.answered = false;
            root.password = "";
            root.clearPassword();

            if (result === PamResult.Success) {
                lock.locked = false;
                Qt.quit();
            } else if (result === PamResult.MaxTries) {
                root.status = "Too many attempts";
            } else if (root.status === "") {
                root.status = "Incorrect password";
            }
        }

        onError: err => {
            root.busy = false;
            root.answered = false;
            root.status = "PAM error: " + PamError.toString(err);
        }
    }

    function tryUnlock() {
        if (root.busy || root.password === "")
            return;

        root.busy = true;
        root.status = "";
        root.answered = false;

        if (!pam.start()) {
            root.busy = false;
            root.status = "Could not start PAM";
        }
    }

    WlSessionLock {
        id: lock

        locked: true

        WlSessionLockSurface {
            color: Theme.canvas

            Wallpaper {
                anchors.fill: parent
            }

            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: bar.panelOpen
                onClicked: bar.closePanels()
            }

            Bar {
                id: bar

                showWorkspaces: false
                showLauncher: false

                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                }

                onPanelOpenChanged: if (!panelOpen)
                    field.forceActiveFocus()
            }

            Card {
                anchors.centerIn: parent

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "Locked"
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: 18
                }

                Rectangle {
                    width: parent.width
                    height: 42
                    radius: Theme.radiusSmall
                    color: Theme.canvas
                    border.width: 1
                    border.color: field.activeFocus ? Theme.focused : Theme.border

                    TextInput {
                        id: field

                        anchors.fill: parent
                        anchors.margins: Theme.pad
                        verticalAlignment: TextInput.AlignVCenter
                        echoMode: TextInput.Password
                        passwordCharacter: "\u2022"
                        enabled: !root.busy
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontBase
                        focus: true

                        onTextEdited: root.password = field.text
                        onAccepted: root.tryUnlock()

                        Component.onCompleted: forceActiveFocus()

                        Connections {
                            target: root

                            function onClearPassword() {
                                field.text = "";
                                field.forceActiveFocus();
                            }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Password"
                            color: Theme.placeholder
                            font: field.font
                            visible: field.text === "" && !root.busy
                        }
                    }
                }

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.busy ? "Checking..." : root.status
                    color: root.status === "" ? Theme.muted : Theme.error
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSmall
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
