-- Lays out the Finder window of the mounted installer volume (argument: volume name)
on run argv
	tell application "Finder"
		tell disk (item 1 of argv)
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {200, 120, 860, 540}
			set opts to the icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to 128
			set background picture of opts to file ".background:background.png"
			set position of item "Alacrium.app" of container window to {165, 205}
			set position of item "Applications" of container window to {495, 205}
			update without registering applications
			delay 2
			close
		end tell
	end tell
end run
