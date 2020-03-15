#!/usr/bin/env python3

import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib
import subprocess
import dbus


class NotificationFetcher(dbus.service.Object):
    _id = 0

    @dbus.service.method("org.freedesktop.Notifications",
                         in_signature='susssasa{ss}i',
                         out_signature='u')
    def Notify(self, app_name, notification_id, app_icon,
               summary, body, actions, hints, expire_timeout):
        if not notification_id:
            self._id += 1
            notification_id = self._id
        # send data notification @default
        subprocess.call(
            ["/usr/lib/qubes/qrexec-client-vm", "",
             "qubes.TrayNotification",
             "/usr/bin/printf", "{}\n{}\n{}\n".format(app_name, summary, body)])
        return notification_id

    @dbus.service.method("org.freedesktop.Notifications", in_signature='',
                         out_signature='as')
    def GetCapabilities(self):
        return "body"

    @dbus.service.signal('org.freedesktop.Notifications', signature='uu')
    def NotificationClosed(self, id_in, reason_in):
        pass

    @dbus.service.method("org.freedesktop.Notifications", in_signature='u',
                         out_signature='')
    def CloseNotification(self, id):
        pass

    @dbus.service.method("org.freedesktop.Notifications", in_signature='',
                         out_signature='ssss')
    def GetServerInformation(self):
        return "qubes.TrayNotification", "https://www.qubes-os.org/", "0.0", "1"


if __name__ == '__main__':
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    session_bus = dbus.SessionBus()
    name = dbus.service.BusName("org.freedesktop.Notifications", session_bus)
    NotificationFetcher(session_bus, '/org/freedesktop/Notifications')
    loop = GLib.MainLoop()
    loop.run()
