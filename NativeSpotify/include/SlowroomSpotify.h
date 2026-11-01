#ifndef SLOWROOM_SPOTIFY_H
#define SLOWROOM_SPOTIFY_H

#include <stdint.h>

uint64_t sr_spotify_connect(const char *access_token);
uint64_t sr_spotify_prepare(const char *access_token, const char *track_id, const char *output_path);
char *sr_spotify_status(uint64_t job_id);
void sr_spotify_cancel(uint64_t job_id);
void sr_spotify_release(uint64_t job_id);
void sr_spotify_forget(void);
void sr_spotify_string_free(char *value);

#endif
