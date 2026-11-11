// Hand-written declarations for the system libarchive (the SDK ships the library, not its headers).
#include <sys/types.h>
struct archive; struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_filter_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
const char *archive_entry_pathname(struct archive_entry *);
long long archive_entry_size(struct archive_entry *);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
const char *archive_error_string(struct archive *);
int archive_read_free(struct archive *);
