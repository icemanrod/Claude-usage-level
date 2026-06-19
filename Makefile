.PHONY: generate build run clean

# Generate the Xcode project from project.yml
generate:
	xcodegen generate

# Build the app in Release mode
build: generate
	xcodebuild \
		-project ClaudeUsageLevel.xcodeproj \
		-scheme ClaudeUsageLevel \
		-configuration Release \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

# Open in Xcode
open: generate
	open ClaudeUsageLevel.xcodeproj

# Build and run
run: build
	open "build/Build/Products/Release/Claude Usage Level.app"

# Create a DMG
dmg: build
	mkdir -p dmg-contents
	cp -R "build/Build/Products/Release/Claude Usage Level.app" dmg-contents/
	ln -sf /Applications dmg-contents/Applications
	hdiutil create \
		-volname "Claude Usage Level" \
		-srcfolder dmg-contents \
		-ov \
		-format UDZO \
		ClaudeUsageLevel.dmg
	rm -rf dmg-contents

# Clean build artifacts
clean:
	rm -rf build ClaudeUsageLevel.xcodeproj ClaudeUsageLevel.dmg dmg-contents
