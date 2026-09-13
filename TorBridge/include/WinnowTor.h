#ifndef WINNOW_TOR_H
#define WINNOW_TOR_H
#include <stdint.h>
int32_t winnow_tor_start(const char *app_owned_directory);
uint8_t winnow_tor_state(void);
uint16_t winnow_tor_port(void);
void winnow_tor_stop(void);
#endif
