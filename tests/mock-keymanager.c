/* Offline tests only: no ADB, router files, or real keys. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned int u32;
int ATP_CFM_ExtWriteCfgFile(void*,int);
static int scenario,count,hasactive,removed,created,saved,enumerated;
static unsigned int removedid;
char *b618_test_getenv(const char *name) {
    if(!strcmp(name,"B618_REPAIR"))return scenario==0 ? 0 : "1";
    if(!strcmp(name,"B618_BACKUP_VERIFIED"))return scenario==2 ? 0 : "1";
    if(!strcmp(name,"B618_RETIRE_OLDEST"))return scenario==3 ? 0 : "1";
    return 0;
}
int KMC_GetMkCount(void){return count;}
int KMC_GetMkByType(u32 d,u32 type,void *key,u32 *len,u32 *id) {
    (void)key;(void)len;
    if(d!=0x41 || type!=3)abort();
    if(scenario==4)return 0x1234;
    if(hasactive){*id=9;return 0;}return 0x9f110c;
}
int KMC_GetMk(int i,void *out) {
    unsigned char *p=out;enumerated++;memset(p,0,32);
    if(scenario==10)return 0x1234;
    p[0]=0x41;p[4]=(unsigned char)(i+1);p[8]=3;p[10]=0;
    p[12]=0xe5;p[13]=7;p[14]=1;p[15]=1;
    if(i==2){p[12]=0xe3;p[4]=17;} /* oldest eligible key is deliberately not ID 1 */
    if(i==0){p[12]=0xe2;p[10]=1;} /* older active key must be skipped */
    if(i==1){p[12]=0xe1;p[0]=0x42;} /* wrong domain must be skipped */
    if(scenario==5)p[10]=1;
    return 0;
}
int KMC_RmvMk(u32 d,u32 id) {
    if(d!=0x41)abort();removed++;removedid=id;
    if(scenario==6)return 0x4321;count--;return 0;
}
int KMC_CreateMk(u32 d,u32 t){
    if(d!=0x41 || t!=3)abort();created++;
    if(scenario==7)return 0x4321;
    count++;if(scenario!=13)hasactive=1;return 0;
}
static int original(void *p,int n){(void)p;(void)n;saved++;return scenario==8 ? 0x4321 : 0;}
void *dlopen(const char *p,int f){(void)p;(void)f;return (void*)1;}
void *dlsym(void *p,const char *n){(void)p;(void)n;return scenario==11 ? 0 : (void*)original;}
int main(void) {
    for(scenario=0;scenario<=14;scenario++) {
        count=scenario==9 ? 100 : (scenario==14 ? 129 : 128);
        hasactive=scenario==1;removed=created=saved=enumerated=0;removedid=0;
        int rc=ATP_CFM_ExtWriteCfgFile(0,0);
        int ok=1;
        if(scenario==0 || scenario==1)ok=rc==0 && !removed && !created && !saved;
        else if(scenario==12)ok=rc==0 && removed==1 && removedid==17 && created==1 && saved==1;
        else if(scenario==9)ok=rc==0 && !removed && created==1 && saved==1;
        else if(scenario==6)ok=rc!=0 && removed==1 && !created && !saved;
        else if(scenario==7)ok=rc!=0 && removed==1 && created==1 && !saved;
        else if(scenario==8)ok=rc!=0 && removed==1 && created==1 && saved==1;
        else if(scenario==13)ok=rc!=0 && removed==1 && created==1 && !saved;
        else ok=rc!=0 && !removed && !created && !saved;
        if(!ok){fprintf(stderr,"FAILED scenario %d rc=%x removed=%d created=%d saved=%d\n",scenario,rc,removed,created,saved);return 1;}
    }
    puts("PASS: 15 offline scenarios; no router contacted.");return 0;
}
