APP_NAME := LoadTube
BIN := .build/apple/Products/Release/$(APP_NAME)
APP_DIR := build/$(APP_NAME).app
ICON_PNG := build/icon_1024.png
ICONSET := build/AppIcon.iconset
ICNS := build/AppIcon.icns
DIST_DIR := dist
DMG := $(DIST_DIR)/$(APP_NAME).dmg
STAGE := build/dmg-stage

.PHONY: all build icon app run install dmg clean

all: app

build:
	swift build -c release --arch arm64 --arch x86_64

icon: $(ICNS)

$(ICON_PNG):
	mkdir -p build
	swift Scripts/make_icon.swift $(ICON_PNG)

$(ICNS): $(ICON_PNG)
	rm -rf $(ICONSET)
	mkdir -p $(ICONSET)
	sips -z 16 16       $(ICON_PNG) --out $(ICONSET)/icon_16x16.png >/dev/null
	sips -z 32 32       $(ICON_PNG) --out $(ICONSET)/icon_16x16@2x.png >/dev/null
	sips -z 32 32       $(ICON_PNG) --out $(ICONSET)/icon_32x32.png >/dev/null
	sips -z 64 64       $(ICON_PNG) --out $(ICONSET)/icon_32x32@2x.png >/dev/null
	sips -z 128 128     $(ICON_PNG) --out $(ICONSET)/icon_128x128.png >/dev/null
	sips -z 256 256     $(ICON_PNG) --out $(ICONSET)/icon_128x128@2x.png >/dev/null
	sips -z 256 256     $(ICON_PNG) --out $(ICONSET)/icon_256x256.png >/dev/null
	sips -z 512 512     $(ICON_PNG) --out $(ICONSET)/icon_256x256@2x.png >/dev/null
	sips -z 512 512     $(ICON_PNG) --out $(ICONSET)/icon_512x512.png >/dev/null
	cp $(ICON_PNG)          $(ICONSET)/icon_512x512@2x.png
	iconutil -c icns $(ICONSET) -o $(ICNS)

app: build icon
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp $(BIN) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	cp $(ICNS) $(APP_DIR)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP_DIR) >/dev/null 2>&1 || true
	@echo "✅ Приложение собрано: $(APP_DIR)"

run: app
	open $(APP_DIR)

install: app
	rm -rf /Applications/$(APP_NAME).app
	ditto $(APP_DIR) /Applications/$(APP_NAME).app
	xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app >/dev/null 2>&1 || true
	@echo "✅ Установлено: /Applications/$(APP_NAME).app"

dmg: app
	rm -rf $(STAGE) $(DIST_DIR)
	mkdir -p $(STAGE) $(DIST_DIR)
	cp -R $(APP_DIR) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	cp Resources/README-DMG.txt "$(STAGE)/Первый запуск.txt"
	cp $(ICNS) $(STAGE)/.VolumeIcon.icns
	SetFile -a C $(STAGE) >/dev/null 2>&1 || true
	xattr -cr $(STAGE)/$(APP_NAME).app >/dev/null 2>&1 || true
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(STAGE) -ov -format UDZO $(DMG) >/dev/null
	@echo "✅ DMG готов: $(DMG)"

clean:
	rm -rf .build build dist
