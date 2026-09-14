import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd
import "theme"

ShellRoot {
    id: root

    property string status: ""
    property bool busy: false

    component Field: Rectangle {
        id: box

        property alias text: input.text
        property alias echoMode: input.echoMode
        property alias input: input
        property string placeholder: ""

        property Item nextInput: null

        signal accepted

        function focusInput() {
            input.forceActiveFocus();
        }

        width: parent ? parent.width : 300
        height: 42
        radius: Theme.radiusSmall
        color: Theme.canvas
        border.width: 1
        border.color: input.activeFocus ? Theme.focused : Theme.border

        TextInput {
            id: input

            anchors.fill: parent
            anchors.margins: Theme.pad
            verticalAlignment: TextInput.AlignVCenter
            passwordCharacter: "•"
            enabled: !root.busy
            color: Theme.fg
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBase

            KeyNavigation.tab: box.nextInput
            KeyNavigation.backtab: box.nextInput

            onAccepted: box.accepted()

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: box.placeholder
                color: Theme.placeholder
                font: input.font
                visible: input.text === ""
            }
        }
    }

    Process {
        running: true
        command: ["/usr/bin/elvos-default-user"]

        stdout: StdioCollector {
            onStreamFinished: {
                const name = text.trim();
                if (name === "" || user.text !== "")
                    return;

                user.text = name;
                password.focusInput();
            }
        }
    }

    Connections {
        target: Greetd

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (responseRequired) {
                Greetd.respond(password.text);
            } else if (error) {
                root.busy = false;
                root.status = message;
            }
        }

        function onAuthFailure(message) {
            root.busy = false;
            root.status = message;
            password.text = "";
            password.focusInput();
        }

        function onReadyToLaunch() {
            Greetd.launch(["niri-session"]);
        }
    }

    function submit() {
        if (root.busy || user.text === "")
            return;

        root.busy = true;
        root.status = "";
        Greetd.createSession(user.text);
    }

    FloatingWindow {
        title: "elvOS Login"

        color: "transparent"
        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight

        Card {
            id: card

            anchors.centerIn: parent

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: Greetd.available ? "elvOS" : "greetd unavailable"
                color: Greetd.available ? Theme.fg : Theme.error
                font.family: Theme.fontFamily
                font.pixelSize: 18
            }

            Field {
                id: user

                placeholder: "Username"
                echoMode: TextInput.Normal
                nextInput: password.input
                onAccepted: password.focusInput()
                Component.onCompleted: focusInput()
            }

            Field {
                id: password

                placeholder: "Password"
                echoMode: TextInput.Password
                nextInput: user.input
                onAccepted: root.submit()
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.busy ? "Authenticating..." : root.status
                color: root.status === "" ? Theme.muted : Theme.error
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
                wrapMode: Text.WordWrap
            }
        }
    }
}
