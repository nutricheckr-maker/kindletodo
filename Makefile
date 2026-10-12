# KindleTodo build helpers.
#   make dist                      -> build/KindleTodo-<ver>.zip (copy its contents to the Kindle's USB root)
#   make test KOREADER_DIR=...     -> run the test suite with a KOReader build's luajit
VERSION := 1.0
DIST    := build/KindleTodo-$(VERSION)

.PHONY: dist test clean

dist:
	rm -rf $(DIST) $(DIST).zip
	mkdir -p $(DIST)/extensions $(DIST)/koreader/plugins
	cp -r src/extensions/kindletodo $(DIST)/extensions/
	cp -r src/koreader/plugins/kindletodo.koplugin $(DIST)/koreader/plugins/
	mkdir -p $(DIST)/documents && cp src/documents/KindleTodo.sh $(DIST)/documents/
	chmod 755 $(DIST)/extensions/kindletodo/bin/kindletodo.sh
	cd $(DIST) && zip -qr ../KindleTodo-$(VERSION).zip .
	@echo "built $(DIST).zip"

test:
	tests/run.sh

clean:
	rm -rf build tests/out
