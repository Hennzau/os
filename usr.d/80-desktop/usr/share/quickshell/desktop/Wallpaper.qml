import QtQuick
import "theme"

Rectangle {
    color: Theme.canvas

    Image {
        anchors.fill: parent
        source: "file:///usr/share/backgrounds/wallpaper.jpg"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true

        opacity: 0
        onStatusChanged: if (status === Image.Ready)
            opacity = 1

        Behavior on opacity {
            NumberAnimation {
                duration: 600
                easing.type: Easing.OutCubic
            }
        }
    }
}
