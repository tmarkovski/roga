// A probe that times Roga's launch, loaded into a test copy of the app with
// DYLD_INSERT_LIBRARIES by measure.sh.
//
// It records, on one clock, from the moment the kernel started the process:
//
// - when the probe itself loaded, which is once dyld has loaded every library
// - when the main run loop first ran, and when AppKit said the app will
//   finish and did finish launching
// - when a window was ordered onto the screen, became key, and when the window
//   server said it was visible
// - every pass of the main run loop, at its end, after Core Animation's commit
// - when history's rows first drew, which is the window showing what it's for
// - every child process the app started, with its arguments, and when it
//   ended, since finding git and opening repositories are all git and a shell
// - with ROGA_PROBE_SAMPLE=1, the main thread's stack about every 0.5 ms
//
// Half a second after history's rows draw, or after ROGA_PROBE_TIMEOUT seconds,
// it writes what it recorded to ROGA_PROBE_LOG and ends the process.
//
//   ROGA_PROBE_LOG         where to write the log (required)
//   ROGA_PROBE_SAMPLE      1 to sample the main thread's stack
//   ROGA_PROBE_TIMEOUT     seconds to wait for history's rows (default 20)
//   ROGA_PROBE_SHELL_HOME  the home folder to give the login shell Roga starts
//                          to read PATH, so that the shell reads the real
//                          dotfiles while the app itself has a test home

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <spawn.h>
#import <stdatomic.h>
#import <sys/sysctl.h>
#import <sys/time.h>

#pragma mark - Clock and log

static mach_timebase_info_data_t timebase;

static double nowMs(void) {
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e6;
}

typedef struct {
    double t;
    const char *kind;
    long a;
    long b;
    /// Text that goes with it, such as a child process's arguments, or NULL.
    char *text;
} Record;

enum { recordCapacity = 200000 };
static Record *records;
static long recordCount;
static os_unfair_lock recordLock = OS_UNFAIR_LOCK_INIT;
/// Whether the probe is recording, which it does from when it loads until it
/// writes the log.
static volatile int recording;

static void recordAt(double t, const char *kind, long a, long b, const char *text) {
    if (!recording) return;
    char *copy = text ? strdup(text) : NULL;
    os_unfair_lock_lock(&recordLock);
    if (recordCount < recordCapacity) {
        records[recordCount++] = (Record){t, kind, a, b, copy};
        copy = NULL;
    }
    os_unfair_lock_unlock(&recordLock);
    free(copy);
}

static void record(const char *kind, long a, long b) {
    recordAt(nowMs(), kind, a, b, NULL);
}

/// When the kernel started this process, on the probe's clock.
static double processStart(void) {
    struct kinfo_proc info;
    size_t size = sizeof info;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return nowMs();
    struct timeval now;
    gettimeofday(&now, NULL);
    double t = nowMs();
    struct timeval start = info.kp_proc.p_starttime;
    double age = (double)(now.tv_sec - start.tv_sec) * 1000.0 + (double)(now.tv_usec - start.tv_usec) / 1000.0;
    return t - age;
}

#pragma mark - Main-thread sampler

enum { sampleCapacity = 100000, maxDepth = 512, pcCapacity = 12000000 };
typedef struct {
    double t;
    long offset;
    int depth;
} Sample;

static Sample *samples;
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
    while (recording) {
        takeSample();
        usleep(400);
    }
    return NULL;
}

#pragma mark - Child processes

/// The home folder the login shell gets, from ROGA_PROBE_SHELL_HOME, or NULL
/// to leave its environment alone.
static const char *shellHome;

static char *joined(char *const argv[]) {
    size_t length = 0;
    for (int index = 0; argv && argv[index]; index++) length += strlen(argv[index]) + 1;
    if (length > 600) length = 600;
    char *text = calloc(length + 1, 1);
    size_t used = 0;
    for (int index = 0; argv && argv[index] && used < length; index++) {
        size_t part = strlen(argv[index]);
        if (used + part + 1 > length) part = length - used - 1;
        if (index > 0) text[used++] = ' ';
        memcpy(text + used, argv[index], part);
        used += part;
    }
    // One line each in the log.
    for (size_t index = 0; index < used; index++) if (text[index] == '\n') text[index] = ' ';
    return text;
}

/// Whether these arguments are the login shell Roga starts to read PATH.
static BOOL isLoginShell(char *const argv[]) {
    if (!argv || !argv[0] || !argv[1] || !argv[2] || !argv[3]) return NO;
    return strcmp(argv[1], "-i") == 0 && strcmp(argv[2], "-l") == 0 && strcmp(argv[3], "-c") == 0;
}

/// The environment with HOME replaced, for the login shell, which the caller frees.
static char **withHome(char *const envp[], const char *home) {
    int count = 0;
    while (envp && envp[count]) count++;
    char **copy = calloc(count + 2, sizeof(char *));
    int used = 0;
    for (int index = 0; index < count; index++) {
        if (strncmp(envp[index], "HOME=", 5) == 0) continue;
        copy[used++] = envp[index];
    }
    char *entry = NULL;
    asprintf(&entry, "HOME=%s", home);
    copy[used++] = entry;
    return copy;
}

static void watchExit(pid_t pid) {
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_event_handler(source, ^{
        record("exit", pid, 0);
        dispatch_source_cancel(source);
    });
    dispatch_resume(source);
}

static int spawnWith(int (*spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]),
                     pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    char **changed = NULL;
    if (shellHome && isLoginShell(argv)) changed = withHome(envp, shellHome);
    pid_t child = 0;
    double t = nowMs();
    int result = spawn(&child, path, actions, attributes, argv, changed ? changed : envp);
    if (changed) {
        for (int index = 0; changed[index]; index++) {
            if (strncmp(changed[index], "HOME=", 5) == 0) free(changed[index]);
        }
        free(changed);
    }
    if (pid) *pid = child;
    char *text = joined(argv);
    recordAt(t, "spawn", result == 0 ? child : -1, (long)((nowMs() - t) * 1000), text);
    free(text);
    if (result == 0) watchExit(child);
    return result;
}

static int probeSpawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    return spawnWith(posix_spawn, pid, path, actions, attributes, argv, envp);
}

static int probeSpawnP(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    return spawnWith(posix_spawnp, pid, file, actions, attributes, argv, envp);
}

// dyld points every other image's calls to posix_spawn at these.
__attribute__((used)) static const struct { const void *replacement; const void *replacee; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)probeSpawn, (const void *)posix_spawn},
    {(const void *)probeSpawnP, (const void *)posix_spawnp},
};

#pragma mark - Hooks

static IMP hook(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"probe: no %@ on %@", NSStringFromSelector(selector), cls);
        return NULL;
    }
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
    return original;
}

/// A window big enough to be a workspace window, rather than a menu or a
/// popover.
static BOOL isWorkspace(NSWindow *window) {
    return window.frame.size.width >= 600 && window.frame.size.height >= 400;
}

static IMP originalOrderWindow;
static void probeOrderWindow(id self, SEL _cmd, NSWindowOrderingMode place, NSInteger other) {
    BOOL interesting = isWorkspace(self);
    if (interesting) record("order-window-begin", place, (long)[self windowNumber]);
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))originalOrderWindow)(self, _cmd, place, other);
    if (interesting) record("order-window-end", place, (long)[self windowNumber]);
}

static IMP originalMakeKeyAndOrderFront;
static void probeMakeKeyAndOrderFront(id self, SEL _cmd, id sender) {
    BOOL interesting = isWorkspace(self);
    if (interesting) record("make-key-and-order-front-begin", (long)[self windowNumber], 0);
    ((void (*)(id, SEL, id))originalMakeKeyAndOrderFront)(self, _cmd, sender);
    if (interesting) record("make-key-and-order-front-end", (long)[self windowNumber], 0);
}

static volatile int historyDrawn;
static void finishSoon(void);

static IMP originalCellDraw;
static void probeCellDraw(id self, SEL _cmd, NSRect rect) {
    BOOL first = !historyDrawn;
    if (first) record("history-draw-begin", 0, 0);
    ((void (*)(id, SEL, NSRect))originalCellDraw)(self, _cmd, rect);
    if (first) {
        historyDrawn = 1;
        record("history-draw-end", 0, 0);
        finishSoon();
    }
}

/// The SwiftUI views the probe notes the first appearance of, by class name.
static IMP originalProgressStart;
static void probeProgressStart(id self, SEL _cmd, id sender) {
    record("spinner-start", 0, 0);
    ((void (*)(id, SEL, id))originalProgressStart)(self, _cmd, sender);
}

static void install(void) {
    originalOrderWindow = hook(NSWindow.class, @selector(orderWindow:relativeTo:), (IMP)probeOrderWindow);
    originalMakeKeyAndOrderFront = hook(NSWindow.class, @selector(makeKeyAndOrderFront:), (IMP)probeMakeKeyAndOrderFront);
    originalProgressStart = hook(NSProgressIndicator.class, @selector(startAnimation:), (IMP)probeProgressStart);
    Class cell = NSClassFromString(@"_TtC9HistoryUI14CommitCellView");
    if (cell) {
        originalCellDraw = hook(cell, @selector(drawRect:), (IMP)probeCellDraw);
    } else {
        NSLog(@"probe: CommitCellView wasn't found, so the probe can't tell when history shows");
    }
}

#pragma mark - Run loop and notifications

static void runLoopObserved(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    record((const char *)info, (long)activity, 0);
}

static void observeRunLoop(void) {
    CFRunLoopRef loop = CFRunLoopGetMain();
    struct { CFRunLoopActivity activity; CFIndex order; const char *name; } observers[] = {
        {kCFRunLoopEntry, LONG_MIN, "rl-entry"},
        {kCFRunLoopAfterWaiting, LONG_MIN, "rl-woke"},
        {kCFRunLoopBeforeWaiting, LONG_MIN, "rl-before-waiting"},
        // After everything else at each stage, including Core Animation's
        // commit, which on macOS 27 can come at a stage other than the one
        // before the run loop waits.
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

static void observeNotifications(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        record("will-finish-launching", 0, 0);
        install();
    }];
    [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        record("did-finish-launching", 0, 0);
    }];
    [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        record("did-become-active", 0, 0);
    }];
    [center addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSWindow *window = note.object;
        if (isWorkspace(window)) record("window-key", window.windowNumber, 0);
    }];
    [center addObserverForName:NSWindowDidChangeOcclusionStateNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSWindow *window = note.object;
        if (isWorkspace(window)) record("window-occlusion", window.windowNumber, (window.occlusionState & NSWindowOcclusionStateVisible) ? 1 : 0);
    }];
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

#pragma mark - Writing the log

static NSString *logPath;
static double startedAt;

static void writeLog(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"# sampling %d\n", sampling];
    [text appendFormat:@"%.4f exec 0 0\n", startedAt];
    for (long index = 0; index < recordCount; index++) {
        Record r = records[index];
        if (r.text) {
            [text appendFormat:@"%.4f %s %ld %ld %s\n", r.t, r.kind, r.a, r.b, r.text];
        } else {
            [text appendFormat:@"%.4f %s %ld %ld\n", r.t, r.kind, r.a, r.b];
        }
    }
    for (long index = 0; index < sampleCount; index++) {
        Sample *sample = &samples[index];
        [text appendFormat:@"%.4f sample", sample->t];
        for (int frame = 0; frame < sample->depth; frame++) [text appendFormat:@" %lx", pcs[sample->offset + frame]];
        [text appendString:@"\n"];
    }
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
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(index);
        [text appendFormat:@"image %lx %lx %s\n", (uintptr_t)header, textSize(header), _dyld_get_image_name(index)];
    }
    [text writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void finish(void) {
    static atomic_flag done = ATOMIC_FLAG_INIT;
    if (atomic_flag_test_and_set(&done)) return;
    record("finish", historyDrawn, 0);
    recording = 0;
    // Let the sampler see that it's over.
    usleep(2000);
    writeLog();
    // Not exit(), which would run the app's handlers for quitting and save
    // state that the next run would then start from.
    _exit(0);
}

static void finishSoon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ finish(); });
}

__attribute__((constructor)) static void start(void) {
    logPath = NSProcessInfo.processInfo.environment[@"ROGA_PROBE_LOG"];
    if (!logPath) return;
    mach_timebase_info(&timebase);
    records = calloc(recordCapacity, sizeof(Record));
    recording = 1;
    startedAt = processStart();
    record("probe-loaded", 0, 0);
    const char *home = getenv("ROGA_PROBE_SHELL_HOME");
    shellHome = home && *home ? strdup(home) : NULL;
    sampling = [NSProcessInfo.processInfo.environment[@"ROGA_PROBE_SAMPLE"] isEqualToString:@"1"];
    if (sampling) {
        samples = calloc(sampleCapacity, sizeof(Sample));
        pcs = calloc(pcCapacity, sizeof(uintptr_t));
        mainThread = mach_thread_self();
        pthread_t main = pthread_self();
        mainStackTop = (uintptr_t)pthread_get_stackaddr_np(main);
        mainStackBottom = mainStackTop - pthread_get_stacksize_np(main);
        pthread_t sampler;
        pthread_create(&sampler, NULL, samplerLoop, NULL);
    }
    observeRunLoop();
    observeNotifications();
    double timeout = NSProcessInfo.processInfo.environment[@"ROGA_PROBE_TIMEOUT"].doubleValue;
    if (timeout <= 0) timeout = 20;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ finish(); });
}
