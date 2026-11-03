// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT
//
// Holds an IPMonitor primary-rank assertion on one interface for as long as
// it runs; configd drops the assertion when this process exits.
//   thrurndis-wifi-rank <ifname> never|last|scoped     assert and stay alive
//   thrurndis-wifi-rank <ifname> get                   print the current rank
// thrurndis-wifi-routed uses it to keep ThruRNDIS's Bond from becoming the Mac's
// primary service. SCNetworkInterfaceSetPrimaryRank is exported but not in
// the public headers, so it is declared here.

#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint32_t PrimaryRank;
enum { kRankDefault = 0, kRankFirst = 1, kRankLast = 2, kRankNever = 3, kRankScoped = 4 };

extern SCNetworkInterfaceRef _SCNetworkInterfaceCreateWithBSDName(CFAllocatorRef, CFStringRef, uint32_t);
extern Boolean SCNetworkInterfaceSetPrimaryRank(SCNetworkInterfaceRef, PrimaryRank);
extern PrimaryRank SCNetworkInterfaceGetPrimaryRank(SCNetworkInterfaceRef);

static const char *rank_names[] = { "default", "first", "last", "never", "scoped" };

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: thrurndis-wifi-rank <ifname> never|last|scoped|get\n");
        return 2;
    }

    CFStringRef name = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    SCNetworkInterfaceRef interface = _SCNetworkInterfaceCreateWithBSDName(NULL, name, 0xffffffff);
    if (interface == NULL) {
        // Bonds live in the preferences rather than IOKit.
        SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("thrurndis-wifi-rank"), NULL);
        CFArrayRef bonds = prefs != NULL ? SCBondInterfaceCopyAll(prefs) : NULL;
        for (CFIndex i = 0; bonds != NULL && i < CFArrayGetCount(bonds); i++) {
            SCNetworkInterfaceRef bond = CFArrayGetValueAtIndex(bonds, i);
            CFStringRef bsdName = SCNetworkInterfaceGetBSDName(bond);
            if (bsdName != NULL && CFEqual(bsdName, name)) {
                interface = (SCNetworkInterfaceRef)CFRetain(bond);
                break;
            }
        }
    }
    if (interface == NULL) {
        fprintf(stderr, "thrurndis-wifi-rank: no interface %s\n", argv[1]);
        return 1;
    }

    if (strcmp(argv[2], "get") == 0) {
        PrimaryRank rank = SCNetworkInterfaceGetPrimaryRank(interface);
        printf("%s\n", rank <= kRankScoped ? rank_names[rank] : "unknown");
        return 0;
    }

    PrimaryRank rank;
    if (strcmp(argv[2], "never") == 0) {
        rank = kRankNever;
    } else if (strcmp(argv[2], "last") == 0) {
        rank = kRankLast;
    } else if (strcmp(argv[2], "scoped") == 0) {
        rank = kRankScoped;
    } else {
        fprintf(stderr, "thrurndis-wifi-rank: unknown rank %s\n", argv[2]);
        return 2;
    }
    if (!SCNetworkInterfaceSetPrimaryRank(interface, rank)) {
        fprintf(stderr, "thrurndis-wifi-rank: setting %s to %s failed: %s\n",
                argv[1], argv[2], SCErrorString(SCError()));
        return 1;
    }
    printf("thrurndis-wifi-rank: holding %s at %s\n", argv[1], argv[2]);
    fflush(stdout);

    // The assertion lives with the IPMonitorControl connection, which
    // re-sends it from its own queue if configd restarts.
    signal(SIGTERM, SIG_DFL);
    dispatch_main();
}
