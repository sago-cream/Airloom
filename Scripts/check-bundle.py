#!/usr/bin/env python3
"""Verify a self-contained universal bundle without launching or changing wallpapers."""
import base64
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.hsi.Torii'
assert info['CFBundleExecutable'] == 'Airloom'
assert info['CFBundleShortVersionString'] == pathlib.Path('VERSION').read_text().strip()
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
assert info['SUPublicEDKey'] == pathlib.Path('Resources/SparklePublicKey.txt').read_text().strip()
assert info['SUFeedURL'] == 'https://github.com/sago-cream/Airloom/releases/latest/download/appcast.xml'
resources = app / 'Contents/Resources'
assert (resources / 'Airloom.icns').is_file()
assert (resources / 'Sparkle-LICENSE').is_file()
helper = resources / 'Airloom.saver'
assert helper.is_dir()
assert not list(app.rglob('*.mp4')), 'User wallpaper must not ship in the app'
assert not list(app.rglob('settings.json'))
for executable in (app / 'Contents/MacOS/Airloom', helper / 'Contents/MacOS/ToriiSaver'):
    arches = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()
    assert set(arches) == {'arm64', 'x86_64'}, arches
    if executable.name == 'Airloom':
        load_commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
        assert '@executable_path/../Frameworks' in load_commands
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(helper)], check=True)
print('Universal app, immutable helper, Sparkle feed/key, icon, framework path and signatures verified.')
