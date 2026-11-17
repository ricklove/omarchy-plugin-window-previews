CXX ?= c++
CPPFLAGS += $(shell pkg-config --cflags hyprland pixman-1 libinput wayland-server json-c)
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++23 -fPIC -fno-gnu-unique -Wall -Wextra -Wno-unused-parameter
TARGET = build/window-previews-hover.so

.PHONY: all check clean
all: $(TARGET)
$(TARGET): hover.cpp TabGeometry.hpp Makefile
	mkdir -p build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -shared hover.cpp -o $@.tmp $(shell pkg-config --libs json-c wayland-server)
	mv $@.tmp $@
check: build/tab-geometry-test
	./build/tab-geometry-test
build/tab-geometry-test: test.cpp TabGeometry.hpp
	mkdir -p build
	$(CXX) -std=c++23 -O2 -Wall -Wextra test.cpp -o $@
clean:
	rm -rf build
