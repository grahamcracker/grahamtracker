APP_NAME    := GrahamTracker
APP         := build/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications

.PHONY: build app install run clean

build:
	swift build

app:
	./scripts/bundle.sh

# Quits the running copy, installs, and relaunches. A running session keeps going across the restart.
install: app
	defaults write com.grahamramsey.GrahamTracker resumeAfterRelaunch -bool YES
	-osascript -e 'quit app "$(APP_NAME)"'
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"

run: app
	open "$(APP)"

clean:
	rm -rf .build build
