#!/usr/bin/python
# -*- coding: utf-8 -*-
import xbmc, xbmcaddon, xbmcgui

LOCAL_PLAYLIST  = "F:/NewKodiProjects/myTV/docs/playlist.m3u8"
LOCAL_EPG       = "F:/NewKodiProjects/myTV/docs/epg.xml.gz"
REMOTE_PLAYLIST = "https://Debe2025.github.io/myTV/playlist.m3u8"
REMOTE_EPG      = "https://Debe2025.github.io/myTV/epg.xml.gz"
COUNTRY         = "Canada"
CHANNELS        = "1644"

def run():
    dialog = xbmcgui.Dialog()
    choice = dialog.select(
        'myTV - Choose Source',
        ['Local files  (works immediately)',
         'GitHub Pages (auto-updates after push)']
    )
    if choice < 0:
        return
    try:
        pvr = xbmcaddon.Addon('pvr.iptvsimple')
        if choice == 0:
            pvr.setSetting('m3uPathType', '0')
            pvr.setSetting('m3uPath',     LOCAL_PLAYLIST)
            pvr.setSetting('epgPathType', '0')
            pvr.setSetting('epgPath',     LOCAL_EPG)
            source = 'Local files'
        else:
            pvr.setSetting('m3uPathType', '1')
            pvr.setSetting('m3uUrl',      REMOTE_PLAYLIST)
            pvr.setSetting('epgPathType', '1')
            pvr.setSetting('epgUrl',      REMOTE_EPG)
            source = 'GitHub Pages'
        pvr.setSetting('m3uCache',               'true')
        pvr.setSetting('m3uRefreshMode',         '2')
        pvr.setSetting('m3uRefreshIntervalMins', '60')
        pvr.setSetting('epgCache',               'true')
        pvr.setSetting('logoPathType',           '1')
        pvr.setSetting('logoBaseUrl', 'https://iptv-org.github.io/iptv/logos/')
        dialog.ok('myTV Setup Complete',
                  'PVR IPTV Simple configured!\n\n'
                  'Source:   ' + source + '\n'
                  'Country:  ' + COUNTRY + '\n'
                  'Channels: ' + CHANNELS + '\n\n'
                  'Restart Kodi, then enable Live TV.')
        xbmc.log('[myTV] Configured with ' + source, xbmc.LOGINFO)
    except Exception as e:
        dialog.ok('myTV Error', 'Could not configure PVR IPTV Simple.\n\nIs it installed?\n\n' + str(e))
        xbmc.log('[myTV] Error: ' + str(e), xbmc.LOGERROR)

if __name__ == '__main__':
    run()
