#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/file.h>
#ifdef __APPLE__
#include <sys/mount.h>
#include <sys/event.h>
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
/* O_SYMLINK opens the link inode itself, including dangling links. O_EVTONLY
   avoids data access; O_NONBLOCK prevents FIFO handshakes. Darwin still checks
   access permissions, so inaccessible foreign entries fail closed. */
#define CLAMP_PATH_FLAGS (O_EVTONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
#define RENAME_NOREPLACE RENAME_EXCL
#define RENAME_EXCHANGE RENAME_SWAP
#else
#include <sys/syscall.h>
#define CLAMP_PATH_FLAGS (O_PATH | O_CLOEXEC | O_NOFOLLOW)
#endif
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

CAMLprim value clamp_monotonic_now(value unit)
{
  CAMLparam1(unit);
  CAMLlocal1(result);
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) == -1)
    uerror("clock_gettime", Nothing);
  result = caml_copy_double((double)now.tv_sec + (double)now.tv_nsec / 1000000000.0);
  CAMLreturn(result);
}

CAMLprim value clamp_waitid_exited_nowait(value process)
{
  CAMLparam1(process);
  siginfo_t information;
  int result;

  memset(&information, 0, sizeof(information));
  do {
    result = waitid(P_PID, (id_t)Int_val(process), &information,
                    WEXITED | WNOHANG | WNOWAIT);
  } while (result == -1 && errno == EINTR);
  if (result == -1) uerror("waitid", Nothing);
  CAMLreturn(Val_bool(information.si_pid == (pid_t)Int_val(process)));
}

CAMLprim value clamp_read_trusted_regular_file(value path, value maximum)
{
  CAMLparam2(path, maximum);
  CAMLlocal1(result);
  struct stat before, after, pathname;
  const int limit = Int_val(maximum);
  int descriptor = -1;
  char *buffer = NULL;
  ssize_t total = 0;

  if (limit < 0) caml_invalid_argument("negative trusted-file limit");
  do {
    descriptor = open(String_val(path), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  } while (descriptor == -1 && errno == EINTR);
  if (descriptor == -1) uerror("open", Nothing);
  if (fstat(descriptor, &before) == -1 ||
      !S_ISREG(before.st_mode) || before.st_uid != geteuid() ||
      (before.st_mode & 022) != 0 || before.st_size < 0 ||
      before.st_size > limit) {
    int saved_errno = errno == 0 ? EINVAL : errno;
    close(descriptor);
    errno = saved_errno;
    uerror("trusted-file", Nothing);
  }

  buffer = caml_stat_alloc((size_t)limit + 1);
  while (total <= limit) {
    ssize_t count = read(descriptor, buffer + total, (size_t)(limit + 1 - total));
    if (count > 0) total += count;
    else if (count == 0) break;
    else if (errno != EINTR) {
      int saved_errno = errno;
      caml_stat_free(buffer);
      close(descriptor);
      errno = saved_errno;
      uerror("read", Nothing);
    }
  }

  if (total > limit || total != before.st_size ||
      fstat(descriptor, &after) == -1 || lstat(String_val(path), &pathname) == -1 ||
      before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
      before.st_mode != after.st_mode || before.st_uid != after.st_uid ||
      before.st_gid != after.st_gid || before.st_size != after.st_size ||
      before.st_mtim.tv_sec != after.st_mtim.tv_sec ||
      before.st_mtim.tv_nsec != after.st_mtim.tv_nsec ||
      before.st_ctim.tv_sec != after.st_ctim.tv_sec ||
      before.st_ctim.tv_nsec != after.st_ctim.tv_nsec ||
      after.st_dev != pathname.st_dev || after.st_ino != pathname.st_ino ||
      after.st_mode != pathname.st_mode || after.st_uid != pathname.st_uid ||
      after.st_gid != pathname.st_gid || after.st_size != pathname.st_size ||
      after.st_mtim.tv_sec != pathname.st_mtim.tv_sec ||
      after.st_mtim.tv_nsec != pathname.st_mtim.tv_nsec ||
      after.st_ctim.tv_sec != pathname.st_ctim.tv_sec ||
      after.st_ctim.tv_nsec != pathname.st_ctim.tv_nsec) {
    caml_stat_free(buffer);
    close(descriptor);
    errno = EINVAL;
    uerror("trusted-file", Nothing);
  }

  if (close(descriptor) == -1) {
    int saved_errno = errno;
    caml_stat_free(buffer);
    errno = saved_errno;
    uerror("close", Nothing);
  }
  result = caml_alloc_initialized_string((mlsize_t)total, buffer);
  caml_stat_free(buffer);
  CAMLreturn(result);
}
#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif

static int qualified_directory(int fd)
{
#ifdef __APPLE__
  struct statfs filesystem;
  int saved_errno = 0;
  if (fstatfs(fd, &filesystem) == -1) saved_errno = errno;
  else if (strcmp(filesystem.f_fstypename, "apfs") != 0 ||
           !(filesystem.f_flags & MNT_LOCAL)) saved_errno = EOPNOTSUPP;
  if (saved_errno) { close(fd); errno = saved_errno; return -1; }
#endif
  return fd;
}

CAMLprim value clamp_open_directory(value path)
{
  CAMLparam1(path);
  int fd = open(String_val(path), O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
  if (fd >= 0) fd = qualified_directory(fd);
  if (fd == -1) uerror("open", path);
  CAMLreturn(Val_int(fd));
}

CAMLprim value clamp_open_directory_at(value directory, value name)
{
  CAMLparam2(directory, name);
  int fd = openat(Int_val(directory), String_val(name),
                  O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
  if (fd >= 0) fd = qualified_directory(fd);
  if (fd == -1) uerror("openat", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value clamp_open_file_at(value directory, value name)
{
  CAMLparam2(directory, name);
  int fd = openat(Int_val(directory), String_val(name),
                  O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  if (fd == -1) uerror("openat", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value clamp_open_path_at(value directory, value name)
{
  CAMLparam2(directory, name);
  int fd = openat(Int_val(directory), String_val(name),
                  CLAMP_PATH_FLAGS);
  if (fd == -1) uerror("openat", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value clamp_create_file_at(value directory, value name)
{
  CAMLparam2(directory, name);
  int fd = openat(Int_val(directory), String_val(name),
                  O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd == -1) uerror("openat", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value clamp_flock(value descriptor, value exclusive)
{
  CAMLparam2(descriptor, exclusive);
  int operation = Bool_val(exclusive) ? LOCK_EX : LOCK_SH;
  while (flock(Int_val(descriptor), operation) == -1) {
    if (errno != EINTR) uerror("flock", Nothing);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_funlock(value descriptor)
{
  CAMLparam1(descriptor);
  while (flock(Int_val(descriptor), LOCK_UN) == -1) {
    if (errno != EINTR) uerror("flock", Nothing);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_mkdir_at(value directory, value name)
{
  CAMLparam2(directory, name);
  if (mkdirat(Int_val(directory), String_val(name), 0755) == -1)
    uerror("mkdirat", name);
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_mkdir_private_at(value directory, value name)
{
  CAMLparam2(directory, name);
  /* Reserve every descriptor needed to witness the new entry before mutation.
     Darwin later retains a duplicate and kqueue for deletion observation;
     Linux observes zero links through the caller-retained descriptor. */
#ifdef __APPLE__
  const int slots = 3;
#else
  const int slots = 1;
#endif
  int reservations[3];
  for (int i = 0; i < slots; i++) {
    do { reservations[i] = open("/dev/null", O_RDONLY | O_CLOEXEC); }
    while (reservations[i] == -1 && errno == EINTR);
    if (reservations[i] == -1) {
      int saved_errno = errno;
      for (int j = 0; j < i; j++) close(reservations[j]);
      errno = saved_errno;
      uerror("open", Nothing);
    }
  }

  int created;
#ifdef __APPLE__
  /* Unlike O_PATH, Darwin entry opens require access permission. Create the
     private directory with its final owner-only mode even under umask 0777.
     This synchronous CLI is single-threaded; no runtime callback or blocking
     section occurs while the process umask is temporarily changed. */
  mode_t previous_mask = umask(0);
#endif
  do {
    created = mkdirat(Int_val(directory), String_val(name), 0700);
  } while (created == -1 && errno == EINTR);
#ifdef __APPLE__
  int creation_errno = errno;
  umask(previous_mask);
  errno = creation_errno;
#endif
  if (created == -1) {
    int saved_errno = errno;
    for (int i = 0; i < slots; i++) close(reservations[i]);
    errno = saved_errno;
    uerror("mkdirat", name);
  }

  /* Closing the reservation makes a descriptor slot available before the
     namespace mutation is opened.  Clamp is single-threaded, so no other
     runtime action can consume the slot between these two syscalls. */
  for (int i = 0; i < slots; i++) close(reservations[i]);
  int fd;
  do {
    fd = openat(Int_val(directory), String_val(name),
                CLAMP_PATH_FLAGS | O_DIRECTORY | O_NOFOLLOW);
  } while (fd == -1 && errno == EINTR);
  if (fd == -1) caml_failwith("private directory open failed");
  CAMLreturn(Val_int(fd));
}

CAMLprim value clamp_chmod_descriptor(value descriptor, value mode)
{
  CAMLparam2(descriptor, mode);
  if (fchmod(Int_val(descriptor), Int_val(mode)) == -1) {
#ifdef __APPLE__
    uerror("fchmod", Nothing);
#else
    if (errno != EBADF) uerror("fchmod", Nothing);
    char path[64];
    int length = snprintf(path, sizeof(path), "/proc/self/fd/%d",
                          Int_val(descriptor));
    if (length < 0 || (size_t)length >= sizeof(path)) {
      errno = EOVERFLOW;
      uerror("snprintf", Nothing);
    }
    if (chmod(path, Int_val(mode)) == -1) uerror("chmod", Nothing);
#endif
  }
  CAMLreturn(Val_unit);
}

static value clamp_renameat2(value olddir, value oldname, value newdir,
                             value newname, unsigned int flags)
{
  CAMLparam4(olddir, oldname, newdir, newname);
#ifdef __APPLE__
  if (renameatx_np(Int_val(olddir), String_val(oldname),
                   Int_val(newdir), String_val(newname), flags) == -1)
    uerror("renameatx_np", oldname);
#elif defined(SYS_renameat2)
  if (syscall(SYS_renameat2, Int_val(olddir), String_val(oldname),
              Int_val(newdir), String_val(newname), flags) == -1)
    uerror("renameat2", oldname);
#else
  errno = ENOSYS;
  uerror("renameat2", oldname);
#endif
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_fsync(value descriptor)
{
  CAMLparam1(descriptor);
  int fd = Int_val(descriptor);
#ifdef __APPLE__
  struct statfs filesystem;
  if (fstatfs(fd, &filesystem) == -1) uerror("fstatfs", Nothing);
  /* Only local APFS has been qualified. No reduced-durability fallback. */
  if (strcmp(filesystem.f_fstypename, "apfs") != 0 ||
      !(filesystem.f_flags & MNT_LOCAL)) {
    errno = EOPNOTSUPP;
    uerror("fsync", Nothing);
  }
#endif
  while (fsync(fd) == -1) {
    if (errno != EINTR) uerror("fsync", Nothing);
  }
#ifdef __APPLE__
  while (fcntl(fd, F_FULLFSYNC) == -1) {
    if (errno != EINTR) uerror("F_FULLFSYNC", Nothing);
  }
#endif
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_descriptor_count(value unit)
{
  CAMLparam1(unit);
#ifdef __APPLE__
  const char *path = "/dev/fd";
#else
  const char *path = "/proc/self/fd";
#endif
  DIR *directory = opendir(path);
  if (directory == NULL) uerror("opendir", Nothing);
  int count = 0;
  struct dirent *entry;
  errno = 0;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) count++;
  }
  int saved_errno = errno;
  closedir(directory);
  if (saved_errno) {
    errno = saved_errno;
    uerror("readdir", Nothing);
  }
  CAMLreturn(Val_int(count));
}

CAMLprim value clamp_rename_noreplace(value olddir, value oldname,
                                      value newdir, value newname)
{
  return clamp_renameat2(olddir, oldname, newdir, newname, RENAME_NOREPLACE);
}

CAMLprim value clamp_rename_exchange(value olddir, value oldname,
                                     value newdir, value newname)
{
  return clamp_renameat2(olddir, oldname, newdir, newname, RENAME_EXCHANGE);
}

CAMLprim value clamp_unlink_at(value directory, value name)
{
  CAMLparam2(directory, name);
  if (unlinkat(Int_val(directory), String_val(name), 0) == -1)
    uerror("unlinkat", name);
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_rmdir_at(value directory, value name)
{
  CAMLparam2(directory, name);
  if (unlinkat(Int_val(directory), String_val(name), AT_REMOVEDIR) == -1)
    uerror("unlinkat", name);
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_descriptor_link_count(value descriptor)
{
  CAMLparam1(descriptor);
  struct stat attributes;
  if (fstat(Int_val(descriptor), &attributes) == -1)
    uerror("fstat", Nothing);
  CAMLreturn(Val_int(attributes.st_nlink));
}

struct removal_watch {
  int fd;
  int queue;
  int deleted;
  int owns_fd;
  dev_t device;
  ino_t inode;
};

static void close_removal_watch(value watch)
{
  struct removal_watch *w = Data_custom_val(watch);
  if (w->queue >= 0) { close(w->queue); w->queue = -1; }
  if (w->fd >= 0 && w->owns_fd) close(w->fd);
  w->fd = -1;
}

static struct custom_operations removal_watch_operations = {
  "clamp.directory-removal", close_removal_watch,
  custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

CAMLprim value clamp_watch_directory_removal(value descriptor)
{
  CAMLparam1(descriptor);
  CAMLlocal1(watch);
  struct stat attributes;
  if (fstat(Int_val(descriptor), &attributes) == -1) uerror("fstat", Nothing);
  if (!S_ISDIR(attributes.st_mode)) caml_invalid_argument("directory witness required");
  watch = caml_alloc_custom(&removal_watch_operations, sizeof(struct removal_watch), 0, 1);
  struct removal_watch *w = Data_custom_val(watch);
  w->fd = -1; w->queue = -1; w->deleted = 0; w->owns_fd = 0;
  w->device = attributes.st_dev; w->inode = attributes.st_ino;
#ifdef __APPLE__
  w->fd = fcntl(Int_val(descriptor), F_DUPFD_CLOEXEC, 0);
  if (w->fd == -1) uerror("fcntl", Nothing);
  w->owns_fd = 1;
  w->queue = kqueue();
  if (w->queue == -1) goto failed;
  if (fcntl(w->queue, F_SETFD, FD_CLOEXEC) == -1) goto failed;
  struct kevent change;
  EV_SET(&change, w->fd, EVFILT_VNODE, EV_ADD | EV_ENABLE | EV_CLEAR,
         NOTE_DELETE | NOTE_REVOKE, 0, NULL);
  if (kevent(w->queue, &change, 1, NULL, 0, NULL) == -1) goto failed;
#else
  /* Linux needs no pre-registered kernel event. The OCaml cleanup paths keep
     this source descriptor open until the witness is closed. */
  w->fd = Int_val(descriptor);
#endif
  CAMLreturn(watch);
#ifdef __APPLE__
failed: {
    int saved_errno = errno;
    close_removal_watch(watch);
    errno = saved_errno;
    uerror("directory-removal-watch", Nothing);
  }
#endif
}

CAMLprim value clamp_directory_removal_observed(value watch)
{
  CAMLparam1(watch);
  struct removal_watch *w = Data_custom_val(watch);
  if (w->fd < 0) caml_invalid_argument("closed directory removal witness");
#ifdef __APPLE__
  if (!w->deleted) {
    struct kevent event;
    struct timespec timeout = {0, 0};
    int count;
    do { count = kevent(w->queue, NULL, 0, &event, 1, &timeout); }
    while (count == -1 && errno == EINTR);
    if (count == -1) uerror("kevent", Nothing);
    if (count == 1 && event.ident == (uintptr_t)w->fd &&
        event.filter == EVFILT_VNODE && !(event.flags & EV_ERROR) &&
        (event.fflags & NOTE_DELETE)) w->deleted = 1;
  }
  CAMLreturn(Val_bool(w->deleted));
#else
  struct stat attributes;
  if (fstat(w->fd, &attributes) == -1) uerror("fstat", Nothing);
  CAMLreturn(Val_bool(attributes.st_dev == w->device &&
                      attributes.st_ino == w->inode &&
                      attributes.st_nlink == 0));
#endif
}

CAMLprim value clamp_close_directory_removal(value watch)
{
  CAMLparam1(watch);
  close_removal_watch(watch);
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_descriptor_owner_mode(value descriptor)
{
  CAMLparam1(descriptor);
  CAMLlocal1(result);
  struct stat attributes;
  if (fstat(Int_val(descriptor), &attributes) == -1)
    uerror("fstat", Nothing);
  result = caml_alloc(2, 0);
  Store_field(result, 0, Val_int(attributes.st_uid));
  Store_field(result, 1, Val_int(attributes.st_mode & 07777));
  CAMLreturn(result);
}

CAMLprim value clamp_effective_uid(value unit)
{
  CAMLparam1(unit);
  CAMLreturn(Val_int(geteuid()));
}

static void finalize_directory_stream(value stream)
{
  DIR **handle = Data_custom_val(stream);
  if (*handle != NULL) {
    closedir(*handle);
    *handle = NULL;
  }
}

static struct custom_operations directory_stream_operations = {
  "clamp.directory-stream",
  finalize_directory_stream,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

CAMLprim value clamp_open_directory_stream(value directory)
{
  CAMLparam1(directory);
  CAMLlocal1(stream);
  stream = caml_alloc_custom(&directory_stream_operations, sizeof(DIR *), 0, 1);
  DIR **handle = Data_custom_val(stream);
  *handle = NULL;
  int duplicate = openat(Int_val(directory), ".",
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (duplicate == -1) uerror("openat", Nothing);
  *handle = fdopendir(duplicate);
  if (*handle == NULL) {
    int error = errno;
    close(duplicate);
    errno = error;
    uerror("fdopendir", Nothing);
  }
  CAMLreturn(stream);
}

CAMLprim value clamp_directory_stream_next(value stream)
{
  CAMLparam1(stream);
  CAMLlocal2(result, name);
  DIR **handle = Data_custom_val(stream);
  if (*handle == NULL) caml_invalid_argument("closed directory stream");
  struct dirent *entry;
  do {
    errno = 0;
    entry = readdir(*handle);
    if (entry == NULL && errno != 0) uerror("readdir", Nothing);
  } while (entry != NULL &&
           (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0));
  if (entry == NULL) CAMLreturn(Val_none);
  name = caml_copy_string(entry->d_name);
  result = caml_alloc(1, 0);
  Store_field(result, 0, name);
  CAMLreturn(result);
}

CAMLprim value clamp_close_directory_stream(value stream)
{
  CAMLparam1(stream);
  finalize_directory_stream(stream);
  CAMLreturn(Val_unit);
}

CAMLprim value clamp_stat_at(value directory, value name)
{
  CAMLparam2(directory, name);
  CAMLlocal1(result);
  struct stat status;
  if (fstatat(Int_val(directory), String_val(name), &status,
              AT_SYMLINK_NOFOLLOW) == -1)
    uerror("fstatat", name);
  int kind = S_ISREG(status.st_mode) ? 0 :
             S_ISDIR(status.st_mode) ? 1 :
             S_ISLNK(status.st_mode) ? 2 : 3;
  result = caml_alloc(8, 0);
  Store_field(result, 0, Val_int(kind));
  Store_field(result, 1, caml_copy_int64(status.st_dev));
  Store_field(result, 2, caml_copy_int64(status.st_ino));
  Store_field(result, 3, caml_copy_int64(status.st_size));
  Store_field(result, 4, caml_copy_int64(status.st_mtim.tv_sec));
  Store_field(result, 5, Val_long(status.st_mtim.tv_nsec));
  Store_field(result, 6, caml_copy_int64(status.st_ctim.tv_sec));
  Store_field(result, 7, Val_long(status.st_ctim.tv_nsec));
  CAMLreturn(result);
}

CAMLprim value clamp_stat_descriptor(value descriptor)
{
  CAMLparam1(descriptor);
  CAMLlocal1(result);
  struct stat status;
  if (fstat(Int_val(descriptor), &status) == -1)
    uerror("fstat", Nothing);
  int kind = S_ISREG(status.st_mode) ? 0 :
             S_ISDIR(status.st_mode) ? 1 :
             S_ISLNK(status.st_mode) ? 2 : 3;
  result = caml_alloc(8, 0);
  Store_field(result, 0, Val_int(kind));
  Store_field(result, 1, caml_copy_int64(status.st_dev));
  Store_field(result, 2, caml_copy_int64(status.st_ino));
  Store_field(result, 3, caml_copy_int64(status.st_size));
  Store_field(result, 4, caml_copy_int64(status.st_mtim.tv_sec));
  Store_field(result, 5, Val_long(status.st_mtim.tv_nsec));
  Store_field(result, 6, caml_copy_int64(status.st_ctim.tv_sec));
  Store_field(result, 7, Val_long(status.st_ctim.tv_nsec));
  CAMLreturn(result);
}
