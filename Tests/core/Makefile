# Builds and runs the Kiln core tests on Linux/macOS (needs a C++17 compiler + OpenSSL 3).
#   make -C Tests/core test
CXX ?= g++
CC ?= gcc
ROOT := ../..
ZSIGN := $(ROOT)/Vendor/zsign/src
OPENSSL_CFLAGS := $(shell pkg-config --cflags openssl)
OPENSSL_LIBS := $(shell pkg-config --libs openssl)
INCLUDES := -I$(ZSIGN) -I$(ZSIGN)/common -I$(ZSIGN)/third-party/zlib -I$(ROOT)/Kiln/Core $(OPENSSL_CFLAGS)
CXXFLAGS := -std=c++17 -O1 -g -Wall -Wno-unused-result -Wno-sign-compare -Wno-unused-variable -Wno-unused-but-set-variable -Wno-deprecated-declarations
OBJDIR := .build

CPP_SRCS := $(wildcard $(ZSIGN)/*.cpp) $(wildcard $(ZSIGN)/common/*.cpp) $(ROOT)/Kiln/Core/kiln_core.cpp
C_SRCS := $(wildcard $(ZSIGN)/third-party/zlib/*.c) $(addprefix $(ZSIGN)/third-party/minizip/,ioapi.c zip.c unzip.c)
OBJS := $(patsubst $(ROOT)/%,$(OBJDIR)/%.o,$(CPP_SRCS) $(C_SRCS))

all: $(OBJDIR)/test_core

$(OBJDIR)/%.cpp.o: $(ROOT)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

$(OBJDIR)/%.c.o: $(ROOT)/%.c
	@mkdir -p $(dir $@)
	$(CC) -O1 -w $(INCLUDES) -c $< -o $@

$(OBJDIR)/test_core: test_core.cpp $(OBJS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) test_core.cpp $(OBJS) $(OPENSSL_LIBS) -o $@

test: $(OBJDIR)/test_core
	./test.sh $(OBJDIR)/test_core

clean:
	rm -rf $(OBJDIR)

.PHONY: all test clean
