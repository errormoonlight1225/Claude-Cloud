#pragma once
#import <Foundation/Foundation.h>

/// Appends a line to /var/mobile/Library/TapRecorder/log.txt (flushed to disk
/// immediately) and to the system log. Used as breadcrumbs so a hang can be
/// located after a reboot by reading the file in Filza.
void TRLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
