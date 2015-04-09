/* Gets time since the epoch in nanoseconds.
 * In principle, may return 0 on error.
 */
MVMuint64 MVM_platform_now(void);

/* Tries to sleep for at least the requested number
 * of nanoseconds.
 */
void MVM_platform_sleep(MVMuint64 nanos);
