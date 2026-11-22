#include <stddef.h>
typedef struct AhampoSession AhampoSession;
AhampoSession *ahampo_session_create(void);
void ahampo_session_destroy(AhampoSession *);
char *ahampo_session_apply(AhampoSession *, const char *);
void ahampo_string_free(char *);
