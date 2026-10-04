// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#include "../codec/RelayDiscCodec.h"
#include <libchdr/chd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// Metadata/track offsets follow MAME's documented CD format: each track is
// padded to four frames; V-prefixed pregaps are stored; CDDA is big endian.
// No untrusted CHD metadata reaches the emulator's cdriso parser.
struct RelayCHD {
    chd_file* file;
    RelayCHDTrack tracks[99];
    uint32_t offsets[99], count, hunkBytes, lastHunk;
    uint8_t* hunk;
};
static uint32_t be32(const uint8_t* b){return (uint32_t)b[0]<<24|(uint32_t)b[1]<<16|(uint32_t)b[2]<<8|b[3];}
static uint64_t be64(const uint8_t* b){return (uint64_t)be32(b)<<32|be32(b+4);}
static uint32_t mode(const char* s){return !strcmp(s,"MODE1_RAW")?1:!strcmp(s,"MODE2_RAW")?2:!strcmp(s,"AUDIO")?3:0;}
void relay_chd_close(RelayCHD* r){if(!r)return;if(r->file)chd_close(r->file);free(r->hunk);free(r);}
RelayCHD* relay_chd_open(const char* path){
    if(!path)return NULL;
    FILE* f=fopen(path,"rb");if(!f)return NULL;
    uint8_t h[124]={0};int valid=fread(h,1,sizeof(h),f)==sizeof(h);
    if(fseek(f,0,SEEK_END)){fclose(f);return NULL;}long fileBytes=ftell(f);
    valid=valid&&fileBytes>=124&&!memcmp(h,"MComprHD",8)&&be32(h+8)==124&&be32(h+12)==5;
    uint64_t logical=valid?be64(h+32):0,meta=valid?be64(h+48):0;
    uint32_t hunk=valid?be32(h+56):0;
    valid=valid&&logical&&logical<=450400ULL*2448&&logical%2448==0&&be32(h+60)==2448
        &&hunk>=2448&&hunk<=512*1024&&hunk%2448==0&&be64(h+40)<(uint64_t)fileBytes;
    for(int i=104;i<124;i++)if(h[i])valid=0; // No external parent dependency.
    // Walk and bound the metadata chain before libchdr searches it; reject
    // cycles, oversized records, GD/DVD images and offsets outside this file.
    uint64_t visited[200];unsigned metadataCount=0;
    while(valid&&meta){
        if(metadataCount>=200||meta>=(uint64_t)fileBytes||fileBytes-(long)meta<16){valid=0;break;}
        for(unsigned i=0;i<metadataCount;i++)if(visited[i]==meta)valid=0;
        if(!valid)break;visited[metadataCount++]=meta;
        uint8_t m[16];if(fseek(f,(long)meta,SEEK_SET)||fread(m,1,16,f)!=16){valid=0;break;}
        uint32_t tag=be32(m),length=be32(m+4)&0xffffff;
        if(length>65536||meta+16+length>(uint64_t)fileBytes||tag==GDROM_TRACK_METADATA_TAG||tag==GDROM_OLD_METADATA_TAG||tag==DVD_METADATA_TAG){valid=0;break;}
        meta=be64(m+8);
    }
    fclose(f);if(!valid)return NULL;
    RelayCHD* r=calloc(1,sizeof(*r));if(!r)return NULL;
    if(chd_open(path,CHD_OPEN_READ,NULL,&r->file)!=CHDERR_NONE)goto fail;
    r->hunkBytes=hunk;r->lastHunk=UINT32_MAX;r->hunk=malloc(hunk);if(!r->hunk)goto fail;
    uint32_t offset=0;
    for(unsigned i=0;i<100;i++){
        char text[256]={0},type[24]={0},sub[24]={0},pgtype[24]={0},pgsub[24]={0};
        uint32_t length=0;int track=0,frames=0,pregap=0,postgap=0,end=0;
        chd_error err=chd_get_metadata(r->file,CDROM_TRACK_METADATA2_TAG,i,text,sizeof(text),&length,NULL,NULL);
        if(err==CHDERR_NONE){
            if(length==0||length>=sizeof(text)||text[length-1]!=0)goto fail;
            if(sscanf(text,"TRACK:%d TYPE:%23s SUBTYPE:%23s FRAMES:%d PREGAP:%d PGTYPE:%23s PGSUB:%23s POSTGAP:%d%n",
                &track,type,sub,&frames,&pregap,pgtype,pgsub,&postgap,&end)!=8)goto fail;
        }else if(err==CHDERR_METADATA_NOT_FOUND){
            err=chd_get_metadata(r->file,CDROM_TRACK_METADATA_TAG,i,text,sizeof(text),&length,NULL,NULL);
            if(err==CHDERR_METADATA_NOT_FOUND)break;
            if(err!=CHDERR_NONE||length==0||length>=sizeof(text)||text[length-1]!=0)goto fail;
            if(sscanf(text,"TRACK:%d TYPE:%23s SUBTYPE:%23s FRAMES:%d%n",&track,type,sub,&frames,&end)!=4)goto fail;
        }else goto fail;
        if(i>=99||text[end]||track!=(int)i+1||frames<=0||frames>450000||pregap<0||pregap>=frames||postgap<0||postgap>4500)goto fail;
        uint32_t m=mode(type);int stored=pgtype[0]=='V';
        if(!m||strcmp(sub,"NONE")|| (pregap&&strcmp(pgsub,"NONE")) || (stored&&mode(pgtype+1)!=m))goto fail;
        if((i==0&&m==3)||(i>0&&m!=3))goto fail; // PS1: one data track, then optional CD audio.
        uint32_t padded=((uint32_t)frames+3)&~3u;
        if(offset+padded>logical/2448)goto fail;
        r->offsets[i]=offset;r->tracks[i]=(RelayCHDTrack){(uint32_t)frames,(uint32_t)pregap,(uint32_t)postgap,m,stored};
        offset+=padded;r->count++;
    }
    if(!r->count||offset!=logical/2448)goto fail;
    return r;
fail:relay_chd_close(r);return NULL;
}
uint32_t relay_chd_track_count(const RelayCHD* r){return r?r->count:0;}
int relay_chd_track(const RelayCHD* r,uint32_t i,RelayCHDTrack* out){if(!r||!out||i>=r->count)return 0;*out=r->tracks[i];return 1;}
int relay_chd_read_sector(RelayCHD* r,uint32_t track,uint32_t sector,uint8_t* out){
    if(!r||!out||track>=r->count||sector>=r->tracks[track].frames)return 0;
    uint64_t offset=(uint64_t)(r->offsets[track]+sector)*2448;
    uint32_t hunk=(uint32_t)(offset/r->hunkBytes),within=(uint32_t)(offset%r->hunkBytes);
    if(r->lastHunk!=hunk){if(chd_read(r->file,hunk,r->hunk)!=CHDERR_NONE)return 0;r->lastHunk=hunk;}
    memcpy(out,r->hunk+within,2352);
    if(r->tracks[track].mode==3)for(unsigned i=0;i<2352;i+=2){uint8_t b=out[i];out[i]=out[i+1];out[i+1]=b;}
    return 1;
}
