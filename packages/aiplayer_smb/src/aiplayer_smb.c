#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include <smb2/libsmb2-share-enum.h>
#if defined(_WIN32)
#define AP __declspec(dllexport)
#else
#define AP __attribute__((visibility("default"))) __attribute__((used))
#endif
typedef struct { int64_t size; int64_t modified; int32_t directory; char name[1024]; uint32_t attributes; } ap_entry;
/* Keep the published field offsets identical on all bundled architectures.
 * attributes occupies the former tail padding on 64-bit targets; 32-bit
 * targets rebuild both this bridge and its Dart FFI declaration together. */
typedef char ap_entry_name_abi[(offsetof(ap_entry, name) == 20) ? 1 : -1];
typedef char ap_entry_attributes_abi[(offsetof(ap_entry, attributes) == 1044) ? 1 : -1];
typedef char ap_entry_size_abi[(sizeof(ap_entry) == 1048) ? 1 : -1];
AP uint32_t ap_entry_size(void) { return (uint32_t)sizeof(ap_entry); }
/* Only numeric errors cross FFI: libsmb2 error strings can contain paths. */
AP int32_t ap_last_error(void *ctx) {
 return ctx ? (int32_t)smb2_get_nterror(ctx) : 0;
}
AP void *ap_connect_options(const char *host,const char *share,const char *user,const char *password,const char *domain,int32_t security,int32_t *error) {
 if(error)*error=0;
 struct smb2_context *ctx=smb2_init_context();
 if(!ctx){if(error)*error=-ENOMEM;return NULL;}
 smb2_set_timeout(ctx,25);
 smb2_set_version(ctx,SMB2_VERSION_ANY);
 if(security==1)smb2_set_sign(ctx,1);
 if(security==2){smb2_set_version(ctx,SMB2_VERSION_ANY3);smb2_set_seal(ctx,1);}
 smb2_set_security_mode(ctx,SMB2_NEGOTIATE_SIGNING_ENABLED);
 smb2_set_user(ctx,user);smb2_set_password(ctx,password);
 if(domain && *domain)smb2_set_domain(ctx,domain);
 int result=smb2_connect_share(ctx,host,share,user);
 if(result<0){
  int32_t status=ap_last_error(ctx);
  if(error)*error=status ? status : result;
  smb2_destroy_context(ctx);return NULL;
 }
 return ctx;
}
AP void *ap_connect_checked(const char *host,const char *share,const char *user,const char *password,const char *domain,int32_t *error) {
 return ap_connect_options(host,share,user,password,domain,0,error);
}
AP int32_t ap_dialect(void *ctx){return smb2_get_dialect(ctx);}
typedef struct {uint32_t type;char name[1024];} ap_share;
AP ap_share *ap_shares(void *ctx,int32_t *count,int32_t *error) {
 *count=0;*error=0;
 struct smb2_share_enum_reply *reply=smb2_share_enum_sync(ctx,SMB2_SHARE_INFO_1);
 if(!reply){*error=ap_last_error(ctx);if(!*error)*error=-9002;return NULL;}
 if(reply->entries_read>65536){smb2_free_data(ctx,reply);*error=-9002;return NULL;}
 ap_share *shares=calloc(reply->entries_read+1,sizeof(ap_share));
 if(!shares){smb2_free_data(ctx,reply);*error=-ENOMEM;return NULL;}
 for(uint32_t i=0;i<reply->entries_read;i++){
  const struct smb2_share_info_1 *info=&reply->share_info.info_1[i];
  if((info->type&3)!=SMB2_SHARE_TYPE_DISKTREE||!info->netname)continue;
  shares[*count].type=info->type;
  strncpy(shares[*count].name,info->netname,sizeof(shares[*count].name)-1);
  (*count)++;
 }
 smb2_free_data(ctx,reply);return shares;
}
AP void ap_free_shares(void *shares){free(shares);}
AP void *ap_connect(const char *host,const char *share,const char *user,const char *password,const char *domain) {
 return ap_connect_checked(host,share,user,password,domain,NULL);
}
AP void ap_disconnect(void *ctx){if(ctx){smb2_disconnect_share(ctx);smb2_destroy_context(ctx);}}
AP int ap_stat(void *ctx,const char *path,ap_entry *out){
 struct smb2_stat_64 st;if(smb2_stat(ctx,path,&st)<0)return -1;
 memset(out,0,sizeof(*out));out->size=(int64_t)st.smb2_size;out->modified=(int64_t)st.smb2_mtime;out->directory=st.smb2_type==SMB2_TYPE_DIRECTORY;out->attributes=st.smb2_attributes;return 0;
}
AP void *ap_opendir(void *ctx,const char *path){return smb2_opendir(ctx,path);}
AP int ap_next(void *ctx,void *dir,ap_entry *out){
 struct smb2dirent *e=smb2_readdir(ctx,dir);if(!e)return 0;
 memset(out,0,sizeof(*out));strncpy(out->name,e->name,sizeof(out->name)-1);
 out->size=(int64_t)e->st.smb2_size;out->modified=(int64_t)e->st.smb2_mtime;out->directory=e->st.smb2_type==SMB2_TYPE_DIRECTORY;out->attributes=e->st.smb2_attributes;return 1;
}
AP void ap_closedir(void *ctx,void *dir){smb2_closedir(ctx,dir);}
AP void *ap_open(void *ctx,const char *path){return smb2_open(ctx,path,O_RDONLY);}
AP int ap_read(void *ctx,void *file,uint8_t *buffer,uint32_t count,uint64_t offset){return smb2_pread(ctx,file,buffer,count,offset);}
AP void ap_close(void *ctx,void *file){smb2_close(ctx,file);}
