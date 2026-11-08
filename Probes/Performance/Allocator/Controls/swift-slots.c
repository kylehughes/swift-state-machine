#include <stddef.h>
extern void swift_release(void *);
static void *slots[40000];
void control_store(size_t i,void *p) { slots[i]=p; }
void control_release(void) { for(size_t i=0;i<40000;i++) { if(slots[i]) swift_release(slots[i]); slots[i]=NULL; } }
