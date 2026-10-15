APP_NAME    := GrahamTracker
APP         := build/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications

.PHONY: build app install run clean

build:
	swift build

app:
	./scripts/bundle.sh

# Quits the running copy (which saves any ongoing session), installs, and relaunches.
install: app
	-osascript -e 'quit app "$(APP_NAME)"'
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"

run: app
	open "$(APP)"

clean:
	rm -rf .build build
