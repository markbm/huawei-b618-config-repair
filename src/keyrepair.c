/* MIT licensed. Target: the exact B618s-22d firmware identified in manifest.json. */
typedef unsigned int u32;
extern int printf(const char *, ...);
extern int fflush(void *);
extern char *getenv(const char *);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern int KMC_GetMkCount(void);
extern int KMC_GetMkByType(u32, u32, void *, u32 *, u32 *);
extern int KMC_GetMk(int, void *);
extern int KMC_CreateMk(u32, u32);
extern int KMC_RmvMk(u32, u32);
#ifndef B618_TEST
__attribute__((constructor)) static void announce(void) {
    printf("B618_HELPER_LOADED v=1\n");fflush((void *)0);
}
#endif

static u32 word(const unsigned char *p) {
    return (u32)p[0] | ((u32)p[1]<<8) | ((u32)p[2]<<16) | ((u32)p[3]<<24);
}
static int yes(const char *name) {
    const char *v=getenv(name); return v && v[0]=='1' && v[1]==0;
}
static int finish(const char *status, int rc) {
    printf("B618_DONE status=%s rc=%x\n",status,rc); fflush((void *)0); return rc;
}
static int active(u32 *id) {
    unsigned char key[256]={0}; u32 len=sizeof(key);
    int rc=KMC_GetMkByType(0x41,3,key,&len,id);
    volatile unsigned char *p=key;
    for(unsigned int i=0;i<sizeof(key);i++)p[i]=0;
    return rc;
}
static int older(const unsigned char *a,const unsigned char *b) {
    unsigned int ay=a[12]+256u*a[13],by=b[12]+256u*b[13];
    if(ay!=by)return ay<by;
    for(int j=14;j<=18;j++)if(a[j]!=b[j])return a[j]<b[j];
    return word(a+4)<word(b+4);
}

/* Interposes only the save entry point in this one dbd process. */
int ATP_CFM_ExtWriteCfgFile(void *data,int opt) {
    u32 id=0; int count=KMC_GetMkCount(),rc=active(&id);
    printf("B618_DIAG domain=41 key_count=%d active_rc=%x active_id=%u\n",count,rc,id);
    fflush((void *)0);
    if(count<0 || count>128)return finish("unsupported-state",1);
    if(!yes("B618_REPAIR"))return finish("diagnosed",0);
    if(!yes("B618_BACKUP_VERIFIED"))return finish("backup-required",1);
    if(rc==0)return finish("already-healthy",0);
    if(rc!=0x9f110c)return finish("unexpected-key-error",rc);
    void *h=dlopen("/app/lib/libdbload.so",2);
    int (*original)(void *,int)=(int (*)(void *,int))dlsym(h,"ATP_CFM_ExtWriteCfgFile");
    if(!h || !original || original==ATP_CFM_ExtWriteCfgFile)return finish("save-function-unavailable",1);
    if(count==128) {
        if(!yes("B618_RETIRE_OLDEST"))return finish("retirement-option-required",1);
        unsigned char candidate[32]={0},entry[32]={0}; int found=0;
        for(int i=0;i<count;i++) {
            int er=KMC_GetMk(i,entry);
            if(er)return finish("key-enumeration-failed",er);
            /* Same domain, type 3, explicitly inactive; never retire an active key. */
            if(word(entry)!=0x41 || entry[8]!=3 || entry[9]!=0 || entry[10]!=0)continue;
            unsigned int year=entry[12]+256u*entry[13];
            if(year<2000 || year>2100 || entry[14]<1 || entry[14]>12 || entry[15]<1 || entry[15]>31)continue;
            if(!found || older(entry,candidate)) {
                for(int j=0;j<32;j++)candidate[j]=entry[j]; found=1;
            }
        }
        if(!found)return finish("no-inactive-config-key",1);
        u32 oldid=word(candidate+4);
        printf("B618_RETIRE domain=41 id=%u created=%u-%02u-%02u\n",oldid,
               candidate[12]+256u*candidate[13],candidate[14],candidate[15]);fflush((void *)0);
        rc=KMC_RmvMk(0x41,oldid);
        if(rc)return finish("retirement-failed",rc);
        if(KMC_GetMkCount()!=127)return finish("unexpected-count-after-retirement",1);
    }
    rc=KMC_CreateMk(0x41,3);
    printf("B618_CREATE rc=%x\n",rc);fflush((void *)0);
    if(rc)return finish("creation-failed",rc);
    id=0;rc=active(&id);
    if(rc)return finish("new-key-unavailable",rc);
    printf("B618_ACTIVE id=%u\n",id);fflush((void *)0);
    rc=original(data,opt);
    return finish(rc ? "save-failed" : "repaired",rc);
}
