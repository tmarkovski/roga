// A probe that measures how long selecting a row in history takes, loaded
// into a test copy of Roga with DYLD_INSERT_LIBRARIES by measure.sh.
//
// It waits for history to show, makes the window key, and then selects rows
// the way someone would: it posts mouse-down and mouse-up events at a row, or
// presses an arrow key. The events go through NSApp.postEvent, so the real
// pointer and keyboard are left alone. While each step runs it records, on one
// clock:
//
// - when the event was posted and when AppKit dispatched it
// - when the row's view became selected, and when it drew its highlight
// - when the history list told the model (tableViewSelectionDidChange:)
// - every pass of the main run loop: when it woke, and when the frame's
//   Core Animation commit finished (an observer just after Core Animation's)
// - the screen's refresh times, from a CVDisplayLink on another thread
// - with ROGA_PROBE_SAMPLE=1, the main thread's stack about every 0.5 ms
//
// It writes them all to ROGA_PROBE_LOG as lines of text, which analyze.py
// turns into timings. Settings come from the environment:
//
//   ROGA_PROBE_LOG     where to write the log (required)
//   ROGA_PROBE_MODE    click (default) or keys, or checks, which clicks,
//                      Shift-clicks, Command-clicks, drags and double-clicks
//                      and writes down what ends up selected (see runChecks),
//                      or hold, which holds down an arrow key (see runHolds)
//   ROGA_PROBE_REPEAT  in hold mode, milliseconds between key repeats (default 33)
//   ROGA_PROBE_HOLDS   in hold mode, how many times to hold a key (default 4),
//                      with ROGA_PROBE_STEPS repeats each time
//   ROGA_PROBE_STEPS   how many rows to select (default 30)
//   ROGA_PROBE_HOLD    milliseconds between mouse-down and mouse-up (default 90)
//   ROGA_PROBE_GAP     milliseconds from one step to the next (default 700)
//   ROGA_PROBE_SAMPLE  1 to sample the main thread's stack during each step
//   ROGA_PROBE_SETTLE  seconds to wait after history shows (default 3)
//   ROGA_PROBE_COMMITS 1 to note whether each highlight is drawn inside a Core
//                      Animation commit, which adds a few milliseconds to it
//   ROGA_PROBE_EXPERIMENT  nopan, nodelay, defer, nomodel, press, mousedown or
//                      override, or several separated by commas, to try changes
//                      without building the app (see experimentNoPan and the rest)

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>

#pragma mark - Clock and log

static mach_timebase_info_data_t timebase;

static double nowMs(void) {
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e6;
}

static double hostToMs(uint64_t host) {
    return (double)host * timebase.numer / timebase.denom / 1e6;
}

typedef struct {
    double t;
    const char *kind;
    long a;
    long b;
} Record;

enum { recordCapacity = 400000 };
static Record *records;
static long recordCount;
static os_unfair_lock recordLock = OS_UNFAIR_LOCK_INIT;
/// Whether a step is running, which is when everything is recorded.
static volatile int armed;
static volatile int stepIndex = -1;

static void record(const char *kind, long a, long b) {
    if (!armed) return;
    double t = nowMs();
    os_unfair_lock_lock(&recordLock);
    if (recordCount < recordCapacity) records[recordCount++] = (Record){t, kind, a, b};
    os_unfair_lock_unlock(&recordLock);
}

#pragma mark - Main-thread sampler

enum { sampleCapacity = 100000, maxDepth = 1024, pcCapacity = 12000000 };
typedef struct {
    double t;
    long offset;
    int depth;
} Sample;

static Sample *samples;
/// Every sample's addresses, one after another, from the leaf.
static uintptr_t *pcs;
static long pcCount;
static volatile long sampleCount;
static thread_t mainThread;
static uintptr_t mainStackTop, mainStackBottom;
static int sampling;

static uintptr_t strip(uintptr_t address) {
    // Return addresses in system code are signed. User addresses fit in 47 bits.
    return address & 0x00007FFFFFFFFFFFULL;
}

static void takeSample(void) {
    if (sampleCount >= sampleCapacity || pcCount + maxDepth > pcCapacity) return;
    Sample *sample = &samples[sampleCount];
    uintptr_t *stack = &pcs[pcCount];
    if (thread_suspend(mainThread) != KERN_SUCCESS) return;
    arm_thread_state64_t state;
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(mainThread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        int depth = 0;
        stack[depth++] = strip((uintptr_t)arm_thread_state64_get_pc(state));
        stack[depth++] = strip((uintptr_t)arm_thread_state64_get_lr(state));
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
        while (depth < maxDepth && fp >= mainStackBottom && fp + 16 <= mainStackTop && (fp & 7) == 0) {
            uintptr_t next = ((uintptr_t *)fp)[0];
            uintptr_t ret = strip(((uintptr_t *)fp)[1]);
            if (ret == 0) break;
            stack[depth++] = ret;
            if (next <= fp) break;
            fp = next;
        }
        thread_resume(mainThread);
        sample->t = nowMs();
        sample->offset = pcCount;
        sample->depth = depth;
        pcCount += depth;
        sampleCount++;
    } else {
        thread_resume(mainThread);
    }
}

static void *samplerLoop(void *unused) {
    for (;;) {
        if (armed && sampling) takeSample();
        usleep(armed && sampling ? 400 : 5000);
    }
    return NULL;
}

#pragma mark - Hooks

static IMP hook(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"probe: no %@ on %@", NSStringFromSelector(selector), cls);
        return NULL;
    }
    IMP original = method_getImplementation(method);
    // Adding it to the class itself leaves superclasses alone when it's inherited.
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
    return original;
}

static NSTableView *historyTable;
static Class commitRowViewClass, commitCellViewClass;

static long rowOf(NSView *view) {
    NSTableView *table = historyTable;
    if (!table) return -1;
    return [table rowForView:view];
}

/// Says which gesture recognizers see a click on the list, and whether they
/// hold back the mouse-down until they've failed.
static void listGestureRecognizers(NSEvent *event) {
    NSView *frameView = event.window.contentView.superview ?: event.window.contentView;
    NSView *hit = [frameView hitTest:event.locationInWindow];
    NSLog(@"probe: the click hits %@", hit);
    for (NSView *view = hit; view; view = view.superview) {
        for (NSGestureRecognizer *recognizer in view.gestureRecognizers) {
            NSString *clicks = [recognizer isKindOfClass:NSClickGestureRecognizer.class]
                ? [NSString stringWithFormat:@" clicks %ld", (long)((NSClickGestureRecognizer *)recognizer).numberOfClicksRequired] : @"";
            NSLog(@"probe: %@%@ on %@: delays primary %d, enabled %d, target %@, action %@, delegate %@, name %@",
                  recognizer.class, clicks, view.class, recognizer.delaysPrimaryMouseButtonEvents, recognizer.isEnabled,
                  [recognizer.target class], NSStringFromSelector(recognizer.action), [recognizer.delegate class], recognizer.name);
        }
    }
}

static IMP originalSendEvent;
static void probeSendEvent(id self, SEL _cmd, NSEvent *event) {
    static int listed;
    if (armed && event.type == NSEventTypeLeftMouseDown && !listed++) listGestureRecognizers(event);
    NSEventType type = event.type;
    BOOL interesting = type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseUp || type == NSEventTypeKeyDown || type == NSEventTypeKeyUp;
    if (armed && !interesting && type != NSEventTypeAppKitDefined && type != NSEventTypeSystemDefined && type != NSEventTypeApplicationDefined) record("send-other", type, 0);
    if (interesting) record("send-begin", type, 0);
    ((void (*)(id, SEL, NSEvent *))originalSendEvent)(self, _cmd, event);
    if (interesting) record("send-end", type, 0);
}

static IMP originalSetSelected;
static void probeSetSelected(id self, SEL _cmd, BOOL selected) {
    BOOL was = ((NSTableRowView *)self).isSelected;
    ((void (*)(id, SEL, BOOL))originalSetSelected)(self, _cmd, selected);
    if (selected != was) record(selected ? "row-selected" : "row-deselected", rowOf(self), 0);
}

/// Whether to look for a commit on the stack whenever the highlight is drawn,
/// from ROGA_PROBE_COMMITS. Looking takes a few milliseconds each time.
static BOOL checkingCommits;

/// Whether a Core Animation commit is on the stack. AppKit lays out and draws
/// from the commit's handlers, so drawing inside one means that commit sends
/// the drawing to the screen once it ends.
static BOOL insideCommit(void) {
    void *frames[256];
    int count = backtrace(frames, 256);
    for (int index = 0; index < count; index++) {
        Dl_info info;
        if (dladdr(frames[index], &info) && info.dli_sname && strstr(info.dli_sname, "Transaction6commit")) return YES;
    }
    return NO;
}

static IMP originalDrawSelection;
static void probeDrawSelection(id self, SEL _cmd, NSRect rect) {
    long row = rowOf(self);
    record("draw-selection-begin", row, armed && checkingCommits ? insideCommit() + 1 : 0);
    ((void (*)(id, SEL, NSRect))originalDrawSelection)(self, _cmd, rect);
    record("draw-selection-end", row, 0);
}

static IMP originalCellDraw;
static void probeCellDraw(id self, SEL _cmd, NSRect rect) {
    long row = rowOf(self);
    record("draw-cell-begin", row, 0);
    ((void (*)(id, SEL, NSRect))originalCellDraw)(self, _cmd, rect);
    record("draw-cell-end", row, 0);
}

/// Experiments, from ROGA_PROBE_EXPERIMENT, a list separated by commas:
///
/// - nopan stops the table's pan gesture recognizer holding back the mouse-down.
/// - nodelay stops every gesture recognizer from the table up to the window's
///   frame holding back the mouse-down.
/// - defer tells the model only once the frame with the highlight is committed.
/// - nomodel doesn't tell the model at all.
/// - press selects the clicked row when the button goes down, from a local
///   event monitor, which runs before the gesture recognizers see the event.
/// - mousedown selects it when the table's mouseDown: runs instead. It changes
///   NSTableView's own method, for this table only, so that CommitTableView
///   doesn't look as if it overrides mouseDown:. The table gets the press in
///   time only with nopan as well.
/// - override gives CommitTableView a mouseDown: that only calls
///   NSTableView's, as `override func mouseDown(with:)` calling super would.
///   AppKit then handles clicks on the table the way it did before gesture
///   recognizers: it selects the row on the press and tracks the mouse until
///   the release.
///
/// press and mousedown act only on a plain single click on a row that isn't
/// already the only one selected, and the click's mouse-up then doesn't report
/// the row to the model a second time (see probeClicked).
static BOOL experimentNoPan, experimentDefer, experimentNoModel, experimentNoDelay, experimentPress, experimentMouseDown, experimentOverride;

/// How many times the model was told about a selection, for the checks: from
/// tableViewSelectionDidChange: and from clicked, or from sendReport in a build
/// that tells the model later.
static long modelReports;
/// Whether the build tells the model from sendReport, after the frame.
static BOOL reportsAreDeferred;

/// The row the last press selected, or -1, so that its mouse-up doesn't report
/// it again.
static long rowSelectedByPress = -1;

/// The row a press should select now, or -1: a plain single click on a row of
/// the list that isn't already the only one selected. Command-, Shift-, Control-
/// and Option-clicks, double-clicks and clicks below the last row are left to
/// AppKit.
static long rowToSelectOnPress(NSEvent *event) {
    NSTableView *table = historyTable;
    if (!table || event.type != NSEventTypeLeftMouseDown || event.window != table.window) return -1;
    if (event.clickCount != 1) return -1;
    NSEventModifierFlags flags = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption;
    if (event.modifierFlags & flags) return -1;
    // Only when the list itself is under the pointer, not a scroller over it.
    NSView *frameView = table.window.contentView.superview ?: table.window.contentView;
    NSView *hit = [frameView hitTest:event.locationInWindow];
    if (!hit || ![hit isDescendantOf:table]) return -1;
    long row = [table rowAtPoint:[table convertPoint:event.locationInWindow fromView:nil]];
    if (row < 0) return -1;
    if (table.selectedRowIndexes.count == 1 && table.selectedRow == row) return -1;
    return row;
}

/// Selects the pressed row, the way a click selects it on mouse-up. The table
/// says the selection changed, which tells the model, as for a click.
static void selectOnPress(NSEvent *event, const char *where) {
    rowSelectedByPress = -1;
    if (event.type != NSEventTypeLeftMouseDown) return;
    record("press-check-begin", 0, 0);
    long row = rowToSelectOnPress(event);
    record("press-check-end", row, 0);
    if (row < 0) return;
    record(where, row, 0);
    rowSelectedByPress = row;
    [historyTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

static IMP originalDidChange;
static void probeDidChange(id self, SEL _cmd, NSNotification *note) {
    if (experimentNoModel) {
        record("did-change-begin", (long)historyTable.selectedRow, 0);
        record("did-change-end", 0, 0);
        return;
    }
    if (experimentDefer) {
        // A timer that's already due fires once the run loop has committed
        // the frame and looks for something to do.
        record("did-change-deferred", (long)historyTable.selectedRow, 0);
        NSTimer *timer = [NSTimer timerWithTimeInterval:0 repeats:NO block:^(NSTimer *unused) {
            record("did-change-begin", (long)historyTable.selectedRow, 0);
            ((void (*)(id, SEL, NSNotification *))originalDidChange)(self, _cmd, note);
            record("did-change-end", 0, 0);
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        return;
    }
    record("did-change-begin", (long)historyTable.selectedRow, 0);
    if (!reportsAreDeferred) modelReports++;
    ((void (*)(id, SEL, NSNotification *))originalDidChange)(self, _cmd, note);
    record("did-change-end", 0, 0);
}

static IMP originalClicked;
/// The table's action, which reports the clicked row again when it's the only
/// one selected, for panels that show something else for it. When the press
/// selected that row, the model has heard about it already.
static void probeClicked(id self, SEL _cmd) {
    long row = historyTable.clickedRow;
    BOOL selectedByPress = (experimentPress || experimentMouseDown) && row >= 0 && row == rowSelectedByPress;
    rowSelectedByPress = -1;
    NSEventModifierFlags flags = NSApp.currentEvent.modifierFlags;
    BOOL wouldReport = row >= 0 && historyTable.selectedRowIndexes.count == 1 && historyTable.selectedRow == row
        && !(flags & (NSEventModifierFlagCommand | NSEventModifierFlagShift));
    record(selectedByPress ? "clicked-skipped" : "clicked", row, wouldReport);
    if (selectedByPress) return;
    if (wouldReport && !reportsAreDeferred) modelReports++;
    ((void (*)(id, SEL))originalClicked)(self, _cmd);
}

static IMP originalSendReport;
/// The controller's timer telling the model what's selected, in a build that
/// waits for the frame.
static void probeSendReport(id self, SEL _cmd) {
    record("report-begin", (long)historyTable.selectedRow, (long)historyTable.selectedRowIndexes.count);
    modelReports++;
    ((void (*)(id, SEL))originalSendReport)(self, _cmd);
    record("report-end", 0, 0);
}

static IMP originalDoubleClicked;
static long doubleClicks;
/// Going to a commit would check it out in the test repository, so this only
/// counts double-clicks.
static void probeDoubleClicked(id self, SEL _cmd) {
    record("double-clicked", historyTable.clickedRow, 0);
    doubleClicks++;
}

static IMP originalTableMouseDown;
/// Takes the place of NSTableView's own mouseDown:, for mousedown.
static void probeTableMouseDown(id self, SEL _cmd, NSEvent *event) {
    BOOL ours = self == historyTable;
    if (ours) record("table-mouse-down-begin", event.clickCount, 0);
    if (ours) selectOnPress(event, "mouse-down-select");
    ((void (*)(id, SEL, NSEvent *))originalTableMouseDown)(self, _cmd, event);
    if (ours) record("table-mouse-down-end", 0, 0);
}

/// CommitTableView's mouseDown:, for override, which only calls NSTableView's.
static void probeOverriddenMouseDown(id self, SEL _cmd, NSEvent *event) {
    record("table-mouse-down-begin", event.clickCount, 0);
    struct objc_super parent = {self, NSTableView.class};
    ((void (*)(struct objc_super *, SEL, NSEvent *))objc_msgSendSuper)(&parent, _cmd, event);
    record("table-mouse-down-end", 0, 0);
}

static IMP originalSetState;
static NSMutableArray<NSString *> *recognizerNames;
static void probeSetState(id self, SEL _cmd, NSGestureRecognizerState state) {
    NSGestureRecognizerState was = ((NSGestureRecognizer *)self).state;
    ((void (*)(id, SEL, NSGestureRecognizerState))originalSetState)(self, _cmd, state);
    if (!armed || state == was) return;
    NSGestureRecognizer *recognizer = self;
    NSString *name = [NSString stringWithFormat:@"%@(%@ on %@)", recognizer.name ?: @"unnamed", recognizer.class, recognizer.view.class];
    NSUInteger index = [recognizerNames indexOfObject:name];
    if (index == NSNotFound) {
        [recognizerNames addObject:name];
        index = recognizerNames.count - 1;
    }
    record("recognizer-state", (long)state, (long)index);
}

static IMP originalPressedButtons;
static volatile int holdingButton;
static NSUInteger probePressedButtons(id self, SEL _cmd) {
    // The table asks whether the button is still down while it tracks a click.
    // A posted click has no real button, so this answers for it.
    record("pressed-buttons", holdingButton, 0);
    if (armed) return holdingButton ? 1 : 0;
    return ((NSUInteger (*)(id, SEL))originalPressedButtons)(self, _cmd);
}

#pragma mark - Run loop and screen

static void runLoopObserved(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    record((const char *)info, (long)activity, 0);
}

static void observeRunLoop(void) {
    CFRunLoopRef loop = CFRunLoopGetMain();
    struct { CFRunLoopActivity activity; CFIndex order; const char *name; } observers[] = {
        {kCFRunLoopAfterWaiting, LONG_MIN, "rl-woke"},
        {kCFRunLoopBeforeWaiting, LONG_MIN, "rl-before-waiting"},
        // Core Animation commits at 2,000,000, so this comes right after it.
        {kCFRunLoopBeforeWaiting, 2000001, "rl-committed"},
        {kCFRunLoopExit, 2000001, "rl-exit"},
        // After everything else at each stage, including a commit made by an
        // observer other than Core Animation's own, as on macOS 27.
        {kCFRunLoopBeforeTimers, LONG_MAX, "rl-done"},
        {kCFRunLoopBeforeSources, LONG_MAX, "rl-done"},
        {kCFRunLoopBeforeWaiting, LONG_MAX, "rl-done"},
        {kCFRunLoopAfterWaiting, LONG_MAX, "rl-done"},
        {kCFRunLoopExit, LONG_MAX, "rl-done"},
    };
    for (size_t index = 0; index < sizeof observers / sizeof observers[0]; index++) {
        CFRunLoopObserverContext context = {0, (void *)observers[index].name, NULL, NULL, NULL};
        CFRunLoopObserverRef observer = CFRunLoopObserverCreate(NULL, observers[index].activity, true, observers[index].order, runLoopObserved, &context);
        CFRunLoopAddObserver(loop, observer, kCFRunLoopCommonModes);
    }
}

// A CVDisplayLink calls back on its own thread, which keeps the main thread
// as it was. Its replacement, NSScreen's display link, calls back on the main thread.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CVDisplayLinkRef displayLink;

static CVReturn screenRefreshed(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *context) {
    if (armed) record("vsync", (long)(hostToMs(now->hostTime) * 1000), (long)(hostToMs(output->hostTime) * 1000));
    return kCVReturnSuccess;
}

#pragma mark - Finding the list

static NSTableView *findTable(NSView *view) {
    if ([NSStringFromClass(view.class) containsString:@"CommitTableView"]) return (NSTableView *)view;
    for (NSView *subview in view.subviews) {
        NSTableView *found = findTable(subview);
        if (found) return found;
    }
    return nil;
}

static NSWindow *findWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible || window.frame.size.width < 600) continue;
        NSTableView *table = findTable(window.contentView.superview ?: window.contentView);
        if (table && table.numberOfRows > 3) {
            historyTable = table;
            return window;
        }
    }
    return nil;
}

#pragma mark - Symbols

/// Every Objective-C method's address and name, sorted by address.
static NSArray *methodsByAddress(void) {
    NSMutableArray *methods = [NSMutableArray array];
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int index = 0; index < classCount; index++) {
        for (int meta = 0; meta < 2; meta++) {
            Class cls = meta ? object_getClass(classes[index]) : classes[index];
            unsigned int methodCount = 0;
            Method *list = class_copyMethodList(cls, &methodCount);
            for (unsigned int m = 0; m < methodCount; m++) {
                NSString *name = [NSString stringWithFormat:@"%c[%s %s]", meta ? '+' : '-', class_getName(classes[index]), sel_getName(method_getName(list[m]))];
                [methods addObject:@{@"address": @((uintptr_t)method_getImplementation(list[m])), @"name": name}];
            }
            free(list);
        }
    }
    free(classes);
    [methods sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"address"] compare:b[@"address"]]; }];
    return methods;
}

static NSDictionary *nearestMethod(NSArray *methods, uintptr_t pc) {
    NSUInteger low = 0, high = methods.count;
    while (low < high) {
        NSUInteger middle = (low + high) / 2;
        if ([methods[middle][@"address"] unsignedLongValue] <= pc) low = middle + 1; else high = middle;
    }
    return low == 0 ? nil : methods[low - 1];
}

static uintptr_t textSize(const struct mach_header_64 *header) {
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, "__TEXT") == 0) return (uintptr_t)segment->vmsize;
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    return 0;
}

#pragma mark - The run

static NSString *logPath;
/// What each of the checks found, in checks mode.
static NSMutableArray<NSString *> *checkResults;

static void writeLog(NSString *mode, int hold, int gap) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"# mode %@ hold %d gap %d sampling %d experiment %@\n", mode, hold, gap, sampling,
        NSProcessInfo.processInfo.environment[@"ROGA_PROBE_EXPERIMENT"].length ? NSProcessInfo.processInfo.environment[@"ROGA_PROBE_EXPERIMENT"] : @"none"];
    [text appendFormat:@"# screen %@ %ld fps\n", historyTable.window.screen.localizedName, (long)historyTable.window.screen.maximumFramesPerSecond];
    for (NSString *line in checkResults) [text appendFormat:@"# %@\n", line];
    for (long index = 0; index < recordCount; index++) {
        Record r = records[index];
        [text appendFormat:@"%.4f %s %ld %ld\n", r.t, r.kind, r.a, r.b];
    }
    for (long index = 0; index < sampleCount; index++) {
        Sample *sample = &samples[index];
        [text appendFormat:@"%.4f sample", sample->t];
        for (int frame = 0; frame < sample->depth; frame++) [text appendFormat:@" %lx", pcs[sample->offset + frame]];
        [text appendString:@"\n"];
    }
    for (NSUInteger index = 0; index < recognizerNames.count; index++) {
        [text appendFormat:@"recognizer %lu %@\n", (unsigned long)index, recognizerNames[index]];
    }
    // Names for the sampled addresses, from what this process knows: the
    // nearest exported symbol, or the nearest Objective-C method if that's
    // closer. analyze.py asks atos for the app's own code, which has its
    // symbols on disk.
    NSMutableSet<NSNumber *> *addresses = [NSMutableSet set];
    for (long index = 0; index < sampleCount; index++) {
        for (int frame = 0; frame < samples[index].depth; frame++) [addresses addObject:@(pcs[samples[index].offset + frame])];
    }
    if (addresses.count > 0) {
        NSArray *methods = methodsByAddress();
        for (NSNumber *number in addresses) {
            uintptr_t pc = number.unsignedLongValue;
            Dl_info info = {0};
            if (!dladdr((void *)pc, &info) || !info.dli_fname) continue;
            NSString *name = info.dli_sname ? @(info.dli_sname) : @"?";
            uintptr_t start = (uintptr_t)info.dli_saddr;
            NSDictionary *method = nearestMethod(methods, pc);
            if (method && [method[@"address"] unsignedLongValue] > start) {
                Dl_info methodInfo = {0};
                dladdr((void *)[method[@"address"] unsignedLongValue], &methodInfo);
                if (methodInfo.dli_fbase == info.dli_fbase) name = method[@"name"];
            }
            [text appendFormat:@"symbol %lx %@ %@\n", pc, [@(info.dli_fname) lastPathComponent], name];
        }
    }
    // The images, so that analyze.py can find the app's own code.
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(index);
        [text appendFormat:@"image %lx %lx %s\n", (uintptr_t)header, textSize(header), _dyld_get_image_name(index)];
    }
    [text writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSPoint clickPoint(long row) {
    NSRect rect = [historyTable rectOfRow:row];
    // Over the date column, away from the graph and any badges.
    NSPoint point = NSMakePoint(NSMaxX(rect) - 150, NSMidY(rect));
    return [historyTable convertPoint:point toView:nil];
}

static void postMouseWith(NSEventType type, NSPoint location, NSInteger windowNumber, long row, NSEventModifierFlags flags, NSInteger clickCount) {
    NSEvent *event = [NSEvent mouseEventWithType:type location:location modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:windowNumber context:nil eventNumber:0 clickCount:clickCount pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
    if (!event) NSLog(@"probe: no event");
    record(type == NSEventTypeLeftMouseDown ? "post-down" : type == NSEventTypeLeftMouseUp ? "post-up" : "post-drag", row, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        record("main-posting", type, 0);
        [NSApp postEvent:event atStart:NO];
    });
}

static void postMouse(NSEventType type, NSPoint location, NSInteger windowNumber, long row) {
    postMouseWith(type, location, windowNumber, row, 0, 1);
}

static void postKeyRepeating(NSEventType type, unsigned short keyCode, unichar character, NSInteger windowNumber, BOOL isARepeat) {
    NSString *characters = [NSString stringWithCharacters:&character length:1];
    NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:NSEventModifierFlagFunction | NSEventModifierFlagNumericPad timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:isARepeat keyCode:keyCode];
    record(type == NSEventTypeKeyDown ? "post-key-down" : "post-key-up", keyCode, 0);
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp postEvent:event atStart:NO]; });
}

static void postKey(NSEventType type, unsigned short keyCode, unichar character, NSInteger windowNumber) {
    postKeyRepeating(type, keyCode, character, windowNumber, NO);
}

static void sleepMs(double ms) {
    usleep((useconds_t)(ms * 1000));
}

#pragma mark - Checks

static NSString *describeRows(NSIndexSet *rows) {
    NSMutableArray *parts = [NSMutableArray array];
    [rows enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        [parts addObject:range.length == 1 ? [NSString stringWithFormat:@"%lu", (unsigned long)range.location]
                                           : [NSString stringWithFormat:@"%lu-%lu", (unsigned long)range.location, (unsigned long)NSMaxRange(range) - 1]];
    }];
    return parts.count ? [parts componentsJoinedByString:@","] : @"none";
}

/// Waits for things to settle, then writes down what's selected and how many
/// times the model was told since the check began.
static void finishCheck(NSString *name, NSString *expected, long reportsBefore, long doubleClicksBefore, int gap) {
    sleepMs(gap);
    __block NSString *selected;
    dispatch_sync(dispatch_get_main_queue(), ^{ selected = describeRows(historyTable.selectedRowIndexes); });
    NSString *line = [NSString stringWithFormat:@"check %@ | selected %@ | expected %@ | model told %ld | double-clicks %ld",
        name, selected, expected, modelReports - reportsBefore, doubleClicks - doubleClicksBefore];
    [checkResults addObject:line];
    NSLog(@"probe: %@", line);
}

static void click(long row, NSEventModifierFlags flags, NSInteger windowNumber, int hold) {
    __block NSPoint location;
    dispatch_sync(dispatch_get_main_queue(), ^{ location = clickPoint(row); });
    holdingButton = 1;
    postMouseWith(NSEventTypeLeftMouseDown, location, windowNumber, row, flags, 1);
    sleepMs(hold);
    holdingButton = 0;
    postMouseWith(NSEventTypeLeftMouseUp, location, windowNumber, row, flags, 1);
}

/// Clicks, Shift-clicks, Command-clicks, drags and double-clicks rows, and
/// writes down what each leaves selected, so that an experiment can be
/// compared with what AppKit does by itself. Control-clicks open a menu, which
/// would stop the probe, so they aren't among them.
static void runChecks(NSInteger windowNumber, long visibleRows, int hold, int gap) {
    checkResults = [NSMutableArray array];
    armed = 1;
    long reports, doubles;

    reports = modelReports; doubles = doubleClicks;
    click(3, 0, windowNumber, hold);
    finishCheck(@"click a row that isn't selected", @"3, told once", reports, doubles, gap);

    reports = modelReports; doubles = doubleClicks;
    click(3, 0, windowNumber, hold);
    finishCheck(@"click the only selected row", @"3, told once", reports, doubles, gap);

    reports = modelReports; doubles = doubleClicks;
    click(6, NSEventModifierFlagShift, windowNumber, hold);
    finishCheck(@"Shift-click", @"3-6", reports, doubles, gap);

    reports = modelReports; doubles = doubleClicks;
    click(8, NSEventModifierFlagCommand, windowNumber, hold);
    finishCheck(@"Command-click", @"3-6,8", reports, doubles, gap);

    reports = modelReports; doubles = doubleClicks;
    click(5, 0, windowNumber, hold);
    finishCheck(@"click a row inside several selected", @"5, told once", reports, doubles, gap);

    // Down on row 2, along to row 7 a few points at a time, and up there.
    reports = modelReports; doubles = doubleClicks;
    __block NSPoint from, to;
    dispatch_sync(dispatch_get_main_queue(), ^{ from = clickPoint(2); to = clickPoint(7); });
    holdingButton = 1;
    postMouseWith(NSEventTypeLeftMouseDown, from, windowNumber, 2, 0, 1);
    sleepMs(60);
    int moves = 30;
    for (int move = 1; move <= moves; move++) {
        NSPoint point = NSMakePoint(from.x, from.y + (to.y - from.y) * move / moves);
        postMouseWith(NSEventTypeLeftMouseDragged, point, windowNumber, -1, 0, 1);
        sleepMs(16);
    }
    sleepMs(60);
    holdingButton = 0;
    postMouseWith(NSEventTypeLeftMouseUp, to, windowNumber, 7, 0, 1);
    finishCheck(@"drag from row 2 to row 7", @"what AppKit does", reports, doubles, gap);

    reports = modelReports; doubles = doubleClicks;
    __block NSPoint location;
    dispatch_sync(dispatch_get_main_queue(), ^{ location = clickPoint(4); });
    holdingButton = 1;
    postMouseWith(NSEventTypeLeftMouseDown, location, windowNumber, 4, 0, 1);
    sleepMs(60);
    holdingButton = 0;
    postMouseWith(NSEventTypeLeftMouseUp, location, windowNumber, 4, 0, 1);
    sleepMs(80);
    holdingButton = 1;
    postMouseWith(NSEventTypeLeftMouseDown, location, windowNumber, 4, 0, 2);
    sleepMs(60);
    holdingButton = 0;
    postMouseWith(NSEventTypeLeftMouseUp, location, windowNumber, 4, 0, 2);
    finishCheck(@"double-click", @"4, one double-click", reports, doubles, gap);
    armed = 0;
}

/// Reads ROGA_PROBE_EXPERIMENT and makes the changes that have to be in place
/// from the start, on the main thread, once the app has finished launching.
static void readExperiments(void) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSArray *experiments = [environment[@"ROGA_PROBE_EXPERIMENT"] ?: @"" componentsSeparatedByString:@","];
    experimentNoPan = [experiments containsObject:@"nopan"];
    experimentDefer = [experiments containsObject:@"defer"];
    experimentNoModel = [experiments containsObject:@"nomodel"];
    experimentNoDelay = [experiments containsObject:@"nodelay"];
    experimentPress = [experiments containsObject:@"press"];
    experimentMouseDown = [experiments containsObject:@"mousedown"];
    experimentOverride = [experiments containsObject:@"override"];
    Class tableClass = NSClassFromString(@"_TtC9HistoryUI15CommitTableView");
    if (experimentOverride && !class_addMethod(tableClass, @selector(mouseDown:), (IMP)probeOverriddenMouseDown, "v@:@")) {
        NSLog(@"probe: CommitTableView already has a mouseDown:");
    }
    if (experimentMouseDown) {
        Method method = class_getInstanceMethod(NSTableView.class, @selector(mouseDown:));
        originalTableMouseDown = method_setImplementation(method, (IMP)probeTableMouseDown);
    }
    if (experimentPress) {
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
            selectOnPress(event, "press-select");
            return event;
        }];
    }
}

#pragma mark - Holding a key

/// Holds down the down arrow, then the up arrow, and so on: a key-down, then
/// after a quarter of a second a repeat every ROGA_PROBE_REPEAT milliseconds,
/// then the key-up. Each hold is a step, from the first key-down until things
/// have settled, and analyze.py says how long each key event waited, how many
/// reports reached the model and how long the selection kept moving after the
/// key came up.
static void runHolds(NSInteger windowNumber, int repeats, int gap) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    int interval = environment[@"ROGA_PROBE_REPEAT"] ? [environment[@"ROGA_PROBE_REPEAT"] intValue] : 33;
    int holds = environment[@"ROGA_PROBE_HOLDS"] ? [environment[@"ROGA_PROBE_HOLDS"] intValue] : 4;
    for (int hold = 0; hold < holds; hold++) {
        BOOL down = hold % 2 == 0;
        unsigned short keyCode = down ? 125 : 126;
        unichar character = down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey;
        __block long startRow = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{ startRow = historyTable.selectedRow; });
        armed = 1;
        record("step", hold, startRow);
        record("hold", down ? 1 : -1, repeats + 1);
        postKeyRepeating(NSEventTypeKeyDown, keyCode, character, windowNumber, NO);
        sleepMs(250);
        for (int repeat = 0; repeat < repeats; repeat++) {
            postKeyRepeating(NSEventTypeKeyDown, keyCode, character, windowNumber, YES);
            sleepMs(interval);
        }
        postKey(NSEventTypeKeyUp, keyCode, character, windowNumber);
        sleepMs(MAX(gap, 1500));
        __block long endRow = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{ endRow = historyTable.selectedRow; });
        record("step-end", hold, endRow);
        armed = 0;
        sleepMs(300);
    }
}

static void runScenario(void) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSString *mode = environment[@"ROGA_PROBE_MODE"] ?: @"click";
    int steps = environment[@"ROGA_PROBE_STEPS"] ? [environment[@"ROGA_PROBE_STEPS"] intValue] : 30;
    int hold = environment[@"ROGA_PROBE_HOLD"] ? [environment[@"ROGA_PROBE_HOLD"] intValue] : 90;
    int gap = environment[@"ROGA_PROBE_GAP"] ? [environment[@"ROGA_PROBE_GAP"] intValue] : 700;
    double settle = environment[@"ROGA_PROBE_SETTLE"] ? [environment[@"ROGA_PROBE_SETTLE"] doubleValue] : 3;
    sampling = [environment[@"ROGA_PROBE_SAMPLE"] isEqualToString:@"1"];
    __block NSWindow *window = nil;
    for (int attempt = 0; attempt < 240 && !window; attempt++) {
        dispatch_sync(dispatch_get_main_queue(), ^{ window = findWindow(); });
        if (!window) sleepMs(500);
    }
    if (!window) {
        [@"# no history found\n" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    // An app started in the background can't make itself active, so this asks
    // measure.sh to, with open -a.
    [@"" writeToFile:[logPath stringByAppendingString:@".activate"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    __block BOOL ready = NO;
    for (int attempt = 0; attempt < 100 && !ready; attempt++) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [window makeKeyAndOrderFront:nil];
            [window makeFirstResponder:historyTable];
            ready = NSApp.isActive && window.isKeyWindow && window.firstResponder == historyTable;
        });
        if (!ready) sleepMs(200);
    }
    NSLog(@"probe: window %@ key %d active %d first responder %@", window, window.isKeyWindow, NSApp.isActive, window.firstResponder);
    if (experimentNoDelay) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            for (NSView *view = historyTable; view; view = view.superview) {
                for (NSGestureRecognizer *recognizer in view.gestureRecognizers) {
                    if (recognizer.delaysPrimaryMouseButtonEvents) {
                        recognizer.delaysPrimaryMouseButtonEvents = NO;
                        NSLog(@"probe: %@ on %@ no longer delays the mouse-down", recognizer.name, view.class);
                    }
                }
            }
        });
    }
    if (experimentNoPan) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            for (NSGestureRecognizer *recognizer in historyTable.gestureRecognizers) {
                if ([recognizer.name isEqualToString:@"NSTableView.mousePanGestureRecognizer"]) {
                    recognizer.delaysPrimaryMouseButtonEvents = NO;
                    NSLog(@"probe: %@ no longer delays the mouse-down", recognizer.name);
                }
            }
        });
    }
    sleepMs(settle * 1000);
    __block NSInteger windowNumber = 0;
    __block long visibleRows = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        windowNumber = window.windowNumber;
        visibleRows = [historyTable rowsInRect:historyTable.visibleRect].length;
        // Row 0 may be uncommitted changes, which show other panels, so the
        // steps start at row 1 and leave row 0 out.
        [historyTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    });
    sleepMs(gap);

    if ([mode isEqualToString:@"hold"]) {
        runHolds(windowNumber, steps, gap);
        dispatch_sync(dispatch_get_main_queue(), ^{ writeLog(mode, hold, gap); });
        [@"" writeToFile:[logPath stringByAppendingString:@".done"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    if ([mode isEqualToString:@"checks"]) {
        runChecks(windowNumber, visibleRows, hold, gap);
        dispatch_sync(dispatch_get_main_queue(), ^{ writeLog(mode, hold, gap); });
        [@"" writeToFile:[logPath stringByAppendingString:@".done"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    long first = 1, last = MAX(2, MIN(visibleRows - 2, 14));
    long previous = 1;
    for (int step = 0; step < steps; step++) {
        stepIndex = step;
        __block NSPoint location;
        long row = 0;
        if ([mode isEqualToString:@"keys"]) {
            // Down to the last of the rows in view, then back up, one row a step.
            long span = last - first;
            long phase = (step + 1) % (2 * span);
            row = first + (phase <= span ? phase : 2 * span - phase);
        } else {
            row = first + (step * 5 + 3) % (last - first + 1);
            if (row == previous) row = row == last ? first : row + 1;
            dispatch_sync(dispatch_get_main_queue(), ^{ location = clickPoint(row); });
            if (step == 0) NSLog(@"probe: clicking row %ld at %@ in window %ld, %ld rows in view", row, NSStringFromPoint(location), (long)windowNumber, visibleRows);
        }
        armed = 1;
        record("step", step, row);
        if ([mode isEqualToString:@"keys"]) {
            BOOL down = row > previous;
            unichar character = down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey;
            postKey(NSEventTypeKeyDown, down ? 125 : 126, character, windowNumber);
            sleepMs(60);
            postKey(NSEventTypeKeyUp, down ? 125 : 126, character, windowNumber);
        } else {
            holdingButton = 1;
            postMouse(NSEventTypeLeftMouseDown, location, windowNumber, row);
            sleepMs(hold);
            holdingButton = 0;
            postMouse(NSEventTypeLeftMouseUp, location, windowNumber, row);
        }
        sleepMs(gap - (([mode isEqualToString:@"keys"]) ? 60 : hold));
        record("step-end", step, row);
        armed = 0;
        previous = row;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{ writeLog(mode, hold, gap); });
    [@"" writeToFile:[logPath stringByAppendingString:@".done"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void install(void) {
    Class app = object_getClass(NSApp);
    originalSendEvent = hook(app, @selector(sendEvent:), (IMP)probeSendEvent);
    NSLog(@"probe: hooked sendEvent: of %@", app);
    commitRowViewClass = NSClassFromString(@"_TtC9HistoryUI13CommitRowView");
    commitCellViewClass = NSClassFromString(@"_TtC9HistoryUI14CommitCellView");
    Class controller = NSClassFromString(@"_TtC9HistoryUI21CommitTableController");
    if (!commitRowViewClass || !commitCellViewClass || !controller) NSLog(@"probe: history's classes weren't found");
    originalSetSelected = hook(commitRowViewClass, @selector(setSelected:), (IMP)probeSetSelected);
    originalDrawSelection = hook(commitRowViewClass, @selector(drawSelectionInRect:), (IMP)probeDrawSelection);
    originalCellDraw = hook(commitCellViewClass, @selector(drawRect:), (IMP)probeCellDraw);
    originalDidChange = hook(controller, @selector(tableViewSelectionDidChange:), (IMP)probeDidChange);
    originalClicked = hook(controller, NSSelectorFromString(@"clicked"), (IMP)probeClicked);
    originalDoubleClicked = hook(controller, NSSelectorFromString(@"doubleClicked"), (IMP)probeDoubleClicked);
    if (class_getInstanceMethod(controller, NSSelectorFromString(@"sendReport"))) {
        reportsAreDeferred = YES;
        originalSendReport = hook(controller, NSSelectorFromString(@"sendReport"), (IMP)probeSendReport);
    }
    if (!NSClassFromString(@"_TtC9HistoryUI15CommitTableView")) NSLog(@"probe: CommitTableView wasn't found");
    recognizerNames = [NSMutableArray array];
    originalSetState = hook(NSGestureRecognizer.class, @selector(setState:), (IMP)probeSetState);
    Class eventMeta = object_getClass(NSEvent.class);
    originalPressedButtons = hook(eventMeta, @selector(pressedMouseButtons), (IMP)probePressedButtons);
    [NSNotificationCenter.defaultCenter addObserverForName:NSTableViewSelectionIsChangingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (note.object == historyTable) record("is-changing", (long)historyTable.selectedRow, 0);
    }];
    readExperiments();
    observeRunLoop();
    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    CVDisplayLinkSetOutputCallback(displayLink, screenRefreshed, NULL);
    CVDisplayLinkStart(displayLink);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ runScenario(); });
}

__attribute__((constructor)) static void start(void) {
    logPath = NSProcessInfo.processInfo.environment[@"ROGA_PROBE_LOG"];
    if (!logPath) return;
    checkingCommits = [NSProcessInfo.processInfo.environment[@"ROGA_PROBE_COMMITS"] isEqualToString:@"1"];
    mach_timebase_info(&timebase);
    records = calloc(recordCapacity, sizeof(Record));
    samples = calloc(sampleCapacity, sizeof(Sample));
    pcs = calloc(pcCapacity, sizeof(uintptr_t));
    mainThread = mach_thread_self();
    pthread_t main = pthread_self();
    mainStackTop = (uintptr_t)pthread_get_stackaddr_np(main);
    mainStackBottom = mainStackTop - pthread_get_stacksize_np(main);
    pthread_t sampler;
    pthread_create(&sampler, NULL, samplerLoop, NULL);
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        install();
    }];
}
