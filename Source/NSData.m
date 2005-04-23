/**
   Copyright (C) 1995, 1996, 1997, 2000, 2002 Free Software Foundation, Inc.

   Written by:  Andrew Kachites McCallum <mccallum@gnu.ai.mit.edu>
   Date: March 1995
   Rewritten by:  Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Date: September 1997

   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.

   <title>NSData class reference</title>
   $Date$ $Revision$
   */

/* NOTES	-	Richard Frith-Macdonald 1997
 *
 *	Rewritten to use the class cluster architecture as in OPENSTEP.
 *
 *	NB. In our implementaion we require an extra primitive for the
 *	    NSMutableData subclasses.  This new primitive method is the
 *	    [-setCapacity:] method, and it differs from [-setLength:]
 *	    as follows -
 *
 *		[-setLength:]
 *			clears bytes when the allocated buffer grows
 *			never shrinks the allocated buffer capacity
 *		[-setCapacity:]
 *			doesn't clear newly allocated bytes
 *			sets the size of the allocated buffer.
 *
 *	The actual class hierarchy is as follows -
 *
 *	NSData					Abstract base class.
 *	    NSDataStatic			Concrete class static buffers.
 *	        NSDataEmpty			Concrete class static buffers.
 *		NSDataMalloc			Concrete class.
 *		    NSDataMappedFile		Memory mapped files.
 *		    NSDataShared		Extension for shared memory.
 *	    NSMutableData			Abstract base class.
 *		NSMutableDataMalloc		Concrete class.
 *		    NSMutableDataShared		Extension for shared memory.
 *
 *	NSMutableDataMalloc MUST share it's initial instance variable layout
 *	with NSDataMalloc so that it can use the 'behavior' code to inherit
 *	methods from NSDataMalloc.
 *
 *	Since all the other subclasses are based on NSDataMalloc or
 *	NSMutableDataMalloc, we can put most methods in here and not
 *	bother with duplicating them in the other classes.
 *		
 */

#if defined(__MINGW32__)
#define UNICODE
#define _UNICODE
#endif
#include "config.h"
#include "GNUstepBase/GSObjCRuntime.h"
#include "Foundation/NSObjCRuntime.h"
#include "Foundation/NSByteOrder.h"
#include "Foundation/NSCoder.h"
#include "Foundation/NSData.h"
#include "Foundation/NSString.h"
#include "Foundation/NSException.h"
#include "Foundation/NSDebug.h"
#include "Foundation/NSFileManager.h"
#include "Foundation/NSPathUtilities.h"
#include "Foundation/NSRange.h"
#include "Foundation/NSURL.h"
#include "Foundation/NSZone.h"
#include <stdio.h>
#include <string.h>		/* for memset() */
#ifdef HAVE_UNISTD_H
#include <unistd.h>             /* SEEK_* on SunOS 4 */
#endif

#ifdef	HAVE_MMAP
#include	<unistd.h>
#include	<sys/mman.h>
#include	<fcntl.h>
#ifndef	MAP_FAILED
#define	MAP_FAILED	((void*)-1)	/* Failure address.	*/
#endif
@class	NSDataMappedFile;
#endif

#ifdef HAVE_SYS_STAT_H
#include <sys/stat.h>
#endif

#ifdef	HAVE_SHMCTL
#include	<sys/ipc.h>
#include	<sys/shm.h>

#define	VM_RDONLY	0644		/* self read/write - other readonly */
#define	VM_ACCESS	0666		/* read/write access for all */
@class	NSDataShared;
@class	NSMutableDataShared;
#endif

@class	NSDataMalloc;
@class	NSDataStatic;
@class	NSMutableDataMalloc;

/*
 *	Some static variables to cache classes and methods for quick access -
 *	these are set up at process startup or in [NSData +initialize]
 */
static SEL	appendSel;
static Class	dataStatic;
static Class	dataMalloc;
static Class	mutableDataMalloc;
static Class	NSDataAbstract;
static Class	NSMutableDataAbstract;
static SEL	appendSel;
static IMP	appendImp;

static BOOL
readContentsOfFile(NSString* path, void** buf, unsigned int* len, NSZone* zone)
{
  NSString 	*localPath = [path localFromOpenStepPath];
	
#if defined(__MINGW__)
  const unichar	*thePath = NULL;
#else
  const char	*thePath = NULL;
#endif	
  FILE		*theFile = 0;
  void		*tmp = 0;
  int		c;
  long		fileLength;
	
#if	GS_WITH_GC == 1
  zone = GSAtomicMallocZone();	// Use non-GC memory inside NSData
#endif
	
#if defined(__MINGW__)
  thePath = [localPath unicharString];
#else
  thePath = [localPath fileSystemRepresentation];
#endif	
  if (thePath == NULL)
    {
      NSWarnFLog(@"Open (%@) attempt failed - bad path",localPath);
      return NO;
    }
	
#if defined(__MINGW__)
  theFile = _wfopen(thePath, L"rb");
#else
  theFile = fopen(thePath, "rb");
#endif	

  if (theFile == NULL)		/* We failed to open the file. */
    {
      NSWarnFLog(@"Open (%@) attempt failed - %s",localPath,
      GSLastErrorStr(errno));
      goto failure;
    }
	
  /*
   *	Seek to the end of the file.
   */
  c = fseek(theFile, 0L, SEEK_END);
  if (c != 0)
    {
      NSWarnFLog(@"Seek to end of file (%@) failed - %s",localPath,
      GSLastErrorStr(errno));
      goto failure;
    }
	
  /*
   *	Determine the length of the file (having seeked to the end of the
   *	file) by calling ftell().
   */
  fileLength = ftell(theFile);
  if (fileLength == -1)
    {
      NSWarnFLog(@"Ftell on %@ failed - %s",localPath,
      GSLastErrorStr(errno));
      goto failure;
    }
	
  /*
   *	Rewind the file pointer to the beginning, preparing to read in
   *	the file.
   */
  c = fseek(theFile, 0L, SEEK_SET);
  if (c != 0)
    {
      NSWarnFLog(@"Fseek to start of file (%@) failed - %s",localPath,
      GSLastErrorStr(errno));
      goto failure;
    }
	
  if (fileLength == 0)
    {
      unsigned char	buf[BUFSIZ];
      
      /*
       * Special case ... a file of length zero may be a named pipe or some
       * file in the /proc filesystem, which will return us data if we read
       * from it ... so we try reading as much as we can.
       */
      while ((c = fread(buf, 1, BUFSIZ, theFile)) != 0)
	{
	  if (tmp == 0)
	    {
	      tmp = NSZoneMalloc(zone, c);
	    }
	  else
	    {
	      tmp = NSZoneRealloc(zone, tmp, fileLength + c);
	    }
	  if (tmp == 0)
	    {
	      NSLog(@"Malloc failed for file (%@) of length %d - %s",localPath,
		fileLength + c, GSLastErrorStr(errno));
	      goto failure;
	    }
	  memcpy(tmp + fileLength, buf, c);
	  fileLength += c;
	}
    }
  else
    {
      tmp = NSZoneMalloc(zone, fileLength);
      if (tmp == 0)
	{
	  NSLog(@"Malloc failed for file (%@) of length %d - %s",localPath,
	  fileLength, GSLastErrorStr(errno));
	  goto failure;
	}
	    
      c = fread(tmp, 1, fileLength, theFile);
      if (c != (int)fileLength)
	{
	  NSWarnFLog(@"read of file (%@) contents failed - %s",localPath,
	  GSLastErrorStr(errno));
	  goto failure;
	}
    }
	
  *buf = tmp;
  *len = fileLength;
  fclose(theFile);
  return YES;
  
  /*
   *	Just in case the failure action needs to be changed.
   */
failure:
  if (tmp != 0)
    {
      NSZoneFree(zone, tmp);
    }
  if (theFile != 0)
    {
      fclose(theFile);
    }
  return NO;
}

/*
 *	NB, The start of the NSMutableDataMalloc instance variables must be
 *	identical to that of NSDataMalloc in order to inherit its methods.
 */
@interface	NSDataStatic : NSData
{
  unsigned	length;
  void		*bytes;
}
@end
@interface	NSDataEmpty: NSDataStatic
@end

@interface	NSDataMalloc : NSDataStatic
{
}
@end

@interface	NSMutableDataMalloc : NSMutableData
{
  unsigned	length;
  void		*bytes;
  NSZone	*zone;
  unsigned	capacity;
  unsigned	growth;
}
/* Increase capacity to at least the specified minimum value.	*/
- (void) _grow: (unsigned int)minimum;
@end

#ifdef	HAVE_MMAP
@interface	NSDataMappedFile : NSDataMalloc
@end
#endif

#ifdef	HAVE_SHMCTL
@interface	NSDataShared : NSDataMalloc
{
  int		shmid;
}
- (id) initWithShmID: (int)anId length: (unsigned int)bufferSize;
@end

@interface	NSMutableDataShared : NSMutableDataMalloc
{
  int		shmid;
}
- (id) initWithShmID: (int)anId length: (unsigned int)bufferSize;
@end
#endif



/**
 *  <p>Class for storing a byte array.  Methods for initializing from memory a
 *  file, or the network are provided, as well as the ability to write to a
 *  file or the network.  If desired, object can take over management of a
 *  pre-allocated buffer (with malloc or similar), free'ing it when deallocated.
 *  </p>
 *  <p>The data buffer at any given time has a <em>capacity</em>, which is the
 *  size of its allocated memory area, in bytes, and a <em>length</em>, which
 *  is the length of data it is currently storing.</p>
 */
@implementation NSData

#if NEED_WORD_ALIGNMENT
static unsigned	gsu16Align;
static unsigned	gsu32Align;
#endif

+ (void) initialize
{
  if (self == [NSData class])
    {
#if NEED_WORD_ALIGNMENT
      gsu16Align = objc_alignof_type(@encode(gsu16));
      gsu32Align = objc_alignof_type(@encode(gsu32));
#endif
      NSDataAbstract = self;
      NSMutableDataAbstract = [NSMutableData class];
      dataMalloc = [NSDataMalloc class];
      dataStatic = [NSDataStatic class];
      mutableDataMalloc = [NSMutableDataMalloc class];
      appendSel = @selector(appendBytes:length:);
      appendImp = [mutableDataMalloc instanceMethodForSelector: appendSel];
    }
}

+ (id) allocWithZone: (NSZone*)z
{
  if (self == NSDataAbstract)
    {
      return NSAllocateObject(dataMalloc, 0, z);
    }
  else
    {
      return NSAllocateObject(self, 0, z);
    }
}

/**
 * Returns an empty data object.
 */
+ (id) data
{
  static NSData	*empty = nil;

  if (empty == nil)
    {
      empty = [NSDataEmpty allocWithZone: NSDefaultMallocZone()];
      empty = [empty initWithBytesNoCopy: 0 length: 0 freeWhenDone: NO];
    }
  return empty;
}

/**
 * Returns an autoreleased data object containing data copied from bytes
 * and with the specified length.  Invokes -initWithBytes:length:
 */
+ (id) dataWithBytes: (const void*)bytes
	      length: (unsigned int)length
{
  NSData	*d;

  d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: bytes length: length];
  return AUTORELEASE(d);
}

/**
 * Returns an autoreleased data object encapsulating the data at bytes
 * and with the specified length.  Invokes
 * -initWithBytesNoCopy:length:freeWhenDone: with YES
 */
+ (id) dataWithBytesNoCopy: (void*)bytes
		    length: (unsigned int)length
{
  NSData	*d;

  d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytesNoCopy: bytes length: length freeWhenDone: YES];
  return AUTORELEASE(d);
}

/**
 * Returns an autoreleased data object encapsulating the data at bytes
 * and with the specified length.  Invokes
 * -initWithBytesNoCopy:length:freeWhenDone:
 */
+ (id) dataWithBytesNoCopy: (void*)aBuffer
		    length: (unsigned int)bufferSize
	      freeWhenDone: (BOOL)shouldFree
{
  NSData	*d;

  if (shouldFree == YES)
    {
      d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
    }
  else
    {
      d = [dataStatic allocWithZone: NSDefaultMallocZone()];
    }
  d = [d initWithBytesNoCopy: aBuffer
		      length: bufferSize
		freeWhenDone: shouldFree];
  return AUTORELEASE(d);
}

/**
 * Returns a data object encapsulating the contents of the specified file.
 * Invokes -initWithContentsOfFile:
 */
+ (id) dataWithContentsOfFile: (NSString*)path
{
  NSData	*d;

  d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithContentsOfFile: path];
  return AUTORELEASE(d);
}

/**
 * Returns a data object encapsulating the contents of the specified
 * file mapped directly into memory.
 * Invokes -initWithContentsOfMappedFile:
 */
+ (id) dataWithContentsOfMappedFile: (NSString*)path
{
  NSData	*d;

#ifdef	HAVE_MMAP
  d = [NSDataMappedFile allocWithZone: NSDefaultMallocZone()];
  d = [d initWithContentsOfMappedFile: path];
#else
  d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithContentsOfMappedFile: path];
#endif
  return AUTORELEASE(d);
}

/**
 * Retrieves the information at the specified url and returns an NSData
 * instance encapsulating it.
 */
+ (id) dataWithContentsOfURL: (NSURL*)url
{
  NSData	*d;

  d = [url resourceDataUsingCache: YES];
  return d;
}

/**
 * Returns an autoreleased instance initialised by copying the contents of data.
 */
+ (id) dataWithData: (NSData*)data
{
  NSData	*d;

  d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: [data bytes] length: [data length]];
  return AUTORELEASE(d);
}

/**
 * Returns a new empty data object.
 */
+ (id) new
{
  NSData	*d;

  d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytesNoCopy: 0 length: 0 freeWhenDone: YES];
  return d;
}

- (id) init
{
   return [self initWithBytesNoCopy: 0 length: 0 freeWhenDone: YES];
}

/**
 * Makes a copy of bufferSize bytes of data at aBuffer, and passes it to
 * -initWithBytesNoCopy:length:freeWhenDone: with a YES argument in order
 * to initialise the receiver.  Returns the result.
 */
- (id) initWithBytes: (const void*)aBuffer
	      length: (unsigned int)bufferSize
{
  void	*ptr = 0;

  if (bufferSize > 0)
    {
      ptr = NSZoneMalloc(NSDefaultMallocZone(), bufferSize);
      if (ptr == 0)
        {
	  DESTROY(self);
	  return nil;
        }
      memcpy(ptr, aBuffer, bufferSize);
    }
  return [self initWithBytesNoCopy: ptr
			    length: bufferSize
		      freeWhenDone: YES];
}

/**
 * Invokes -initWithBytesNoCopy:length:freeWhenDone: with the last argument
 * set to YES.  Returns the resulting initialised data object (which may not
 * be the receiver).
 */
- (id) initWithBytesNoCopy: (void*)aBuffer
		    length: (unsigned int)bufferSize
{
  return [self initWithBytesNoCopy: aBuffer
			    length: bufferSize
		      freeWhenDone: YES];
}

/** <init /><override-subclass />
 * Initialises the receiver.<br />
 * The value of aBuffer is a pointer to something to be stored.<br />
 * The value of bufferSize is the number of bytes to use.<br />
 * The value of shouldFree specifies whether the receiver should
 * attempt to free the memory pointer to by aBuffer when the receiver
 * is deallocated ... ie. it says whether the receiver <em>owns</em>
 * the memory.  Supplying the wrong value here will lead to memory
 * leaks or crashes.
 */
- (id) initWithBytesNoCopy: (void*)aBuffer
		    length: (unsigned int)bufferSize
	      freeWhenDone: (BOOL)shouldFree
{
  [self subclassResponsibility: _cmd];
  return nil;
}

/**
 * Initialises the receiver with the contents of the specified file.<br />
 * Returns the resulting object.<br />
 * Returns nil if the file does not exist or can not be read for some reason.
 */
- (id) initWithContentsOfFile: (NSString*)path
{
  void		*fileBytes;
  unsigned	fileLength;
  NSZone	*zone;

#if	GS_WITH_GC
  zone = GSAtomicMallocZone();
#else
  zone = GSObjCZone(self);
#endif
  if (readContentsOfFile(path, &fileBytes, &fileLength, zone) == NO)
    {
      DESTROY(self);
    }
  else
    {
      self = [self initWithBytesNoCopy: fileBytes
				length: fileLength
			  freeWhenDone: YES];
    }
  return self;
}

/**
 *  Initialize with data pointing to contents of file at path.  Bytes are
 *  only "swapped in" as needed.  File should not be moved or deleted for
 *  the life of this object.
 */
- (id) initWithContentsOfMappedFile: (NSString *)path
{
#ifdef	HAVE_MMAP
  NSZone	*z = GSObjCZone(self);
  RELEASE(self);
  self = [NSDataMappedFile allocWithZone: z];
  return [self initWithContentsOfMappedFile: path];
#else
  return [self initWithContentsOfFile: path];
#endif
}

/**
 *  Initialize with data pointing to contents of URL, which will be
 *  retrieved immediately in a blocking manner.
 */
- (id) initWithContentsOfURL: (NSURL*)url
{
  NSData	*data = [url resourceDataUsingCache: YES];

  return [self initWithData: data];
}

/**
 *  Initializes by copying data's bytes into a new buffer.
 */
- (id) initWithData: (NSData*)data
{
  if (data == nil)
    {
      return [self initWithBytesNoCopy: 0 length: 0 freeWhenDone: YES];
    }
  if ([data isKindOfClass: [NSData class]] == NO)
    {
      NSLog(@"-initWithData: passed a non-data object");
      RELEASE(self);
      return nil;
    }
  return [self initWithBytes: [data bytes] length: [data length]];
}


// Accessing Data

/** <override-subclass>
 * Returns a pointer to the data encapsulated by the receiver.
 */
- (const void*) bytes
{
  [self subclassResponsibility: _cmd];
  return NULL;
}

/**
 *  Returns a short description of this object.
 */
- (NSString*) description
{
  extern void     GSPropertyListMake(id,NSDictionary*,BOOL,BOOL,unsigned,id*);
  NSMutableString       *result = nil;

  GSPropertyListMake(self, nil, NO, YES, 0, &result);
  return result;
}

/**
 * Copies the contents of the memory encapsulated by the receiver into
 * the specified buffer.  The buffer must be large enough to contain
 * -length bytes of data ... if it isn't then a crash is likely to occur.<br />
 * Invokes -getBytes:range: with the range set to the whole of the receiver.
 */
- (void) getBytes: (void*)buffer
{
  [self getBytes: buffer range: NSMakeRange(0, [self length])];
}

/**
 * Copies length bytes of data from the memory encapsulated by the receiver
 * into the specified buffer.  The buffer must be large enough to contain
 * length bytes of data ... if it isn't then a crash is likely to occur.<br />
 * Invokes -getBytes:range: with the range set to iNSMakeRange(0, length)
 */
- (void) getBytes: (void*)buffer length: (unsigned int)length
{
  [self getBytes: buffer range: NSMakeRange(0, length)];
}

/**
 * Copies data from the memory encapsulated by the receiver (in the range
 * specified by aRange) into the specified buffer.<br />
 * The buffer must be large enough to contain the data ... if it isn't then
 * a crash is likely to occur.<br />
 * If aRange specifies a range which does not entirely lie within the
 * receiver, an exception is raised.
 */
- (void) getBytes: (void*)buffer range: (NSRange)aRange
{
  unsigned	size = [self length];

  GS_RANGE_CHECK(aRange, size);
  memcpy(buffer, [self bytes] + aRange.location, aRange.length);
}

- (id) replacementObjectForPortCoder: (NSPortCoder*)aCoder
{
  return self;
}

/**
 * Returns an NSData instance encapsulating the memory from the reciever
 * specified by the range aRange.<br />
 * If aRange specifies a range which does not entirely lie within the
 * receiver, an exception is raised.
 */
- (NSData*) subdataWithRange: (NSRange)aRange
{
  void		*buffer;
  unsigned	l = [self length];

  GS_RANGE_CHECK(aRange, l);

#if	GS_WITH_GC
  buffer = NSZoneMalloc(GSAtomicMallocZone(), aRange.length);
#else
  buffer = NSZoneMalloc([self zone], aRange.length);
#endif
  if (buffer == 0)
    {
      [NSException raise: NSMallocException
		  format: @"No memory for subdata of NSData object"];
    }
  [self getBytes: buffer range: aRange];

  return [NSData dataWithBytesNoCopy: buffer length: aRange.length];
}

- (unsigned int) hash
{
  unsigned char	buf[64];
  unsigned	l = [self length];
  unsigned	ret =0;

  l = MIN(l,64);

  /*
   * hash for empty data matches hash for empty string
   */
  if (l == 0)
    {
      return 0xfffffffe;
    }

  [self getBytes: &buf range: NSMakeRange(0, l)];

  while (l-- > 0)
    {
      ret = (ret << 5) + ret + buf[l];
    }
  // Again, match NSString
  if (ret == 0)
    {
       ret = 0xffffffff;
    }
  return ret;
}

- (BOOL) isEqual: anObject
{
  if ([anObject isKindOfClass: [NSData class]])
    return [self isEqualToData: anObject];
  return NO;
}

/**
 * Returns a boolean value indicating if the receiver and other contain
 * identical data (using a byte by byte comparison).  Assumes that the
 * other object is an NSData instance ... may raise an exception if it isn't.
 */
- (BOOL) isEqualToData: (NSData*)other
{
  unsigned int len;
  if (other == self)
    {
      return YES;
    }
  if ((len = [self length]) != [other length])
    {
      return NO;
    }
  return (memcmp([self bytes], [other bytes], len) ? NO : YES);
}

/** <override-subclass>
 * Returns the number of bytes of data encapsulated by the receiver.
 */
- (unsigned int) length
{
  /* This is left to concrete subclasses to implement. */
  [self subclassResponsibility: _cmd];
  return 0;
}

/**
 * <p>Writes a copy of the data encapsulated by the receiver to a file
 * at path.  If the useAuxiliaryFile flag is YES, this writes to a
 * temporary file and then renames that to the file at path, thus
 * ensuring that path exists and does not contain partially written
 * data at any point.
 * </p>
 * <p>On success returns YES, on failure returns NO.
 * </p>
 */
- (BOOL) writeToFile: (NSString*)path atomically: (BOOL)useAuxiliaryFile
{
	NSString *localPath = [path localFromOpenStepPath];
#if defined(__MINGW__)
	unichar		wthePath[[localPath length]+100];
	unichar		wtheRealPath[[localPath length]+100];
#else
	char		thePath[BUFSIZ*2+8];
	char		theRealPath[BUFSIZ*2];
#endif
	int		c;
	FILE		*theFile;
	BOOL		error_BadPath = YES;

#if defined(__MINGW__)
	[localPath getCharacters:wtheRealPath];
	wtheRealPath[[localPath length]] = L'\0';
	error_BadPath = ([localPath length] <= 0);
#else
	if ([localPath canBeConvertedToEncoding: [NSString defaultCStringEncoding]])
	{	
		const char *local_c_path = [localPath cString];
		if (local_c_path != NULL && strlen(local_c_path) < (BUFSIZ*2))
		{	
			strcpy(theRealPath,local_c_path);
			error_BadPath = NO;
		}	
	}
#endif

	if (error_BadPath)
	{
		NSWarnMLog(@"Open (%@) attempt failed - bad path",path);
		return NO;
	}

#ifdef	HAVE_MKSTEMP
  if (useAuxiliaryFile)
    {
      int	desc;
      int	mask;

      strcpy(thePath, theRealPath);
      strcat(thePath, "XXXXXX");
      if ((desc = mkstemp(thePath)) < 0)
	{
          NSWarnMLog(@"mkstemp (%s) failed - %s", thePath,
	    GSLastErrorStr(errno));
          goto failure;
	}
      mask = umask(0);
      umask(mask);
      fchmod(desc, 0644 & ~mask);
      if ((theFile = fdopen(desc, "w")) == 0)
	{
	  close(desc);
	}
    }
  else
    {
      strcpy(thePath, theRealPath);
      theFile = fopen(thePath, "wb");
    }
#else
  if (useAuxiliaryFile)
    {
      /* Use the path name of the destination file as a prefix for the
       * mktemp() call so that we can be sure that both files are on
       * the same filesystem and the subsequent rename() will work. */
#if defined(__MINGW__)
      wcscpy(wthePath, wtheRealPath);
      wcscat(wthePath, L"XXXXXX");
      if (_wmktemp(wthePath) == 0)
	{
	  NSWarnMLog(@"mktemp (%@) failed - %s",
	  [NSString stringWithCharacters:wthePath length:wcslen(wthePath)],
	  GSLastErrorStr(errno));
	  goto failure;
	}
#else
      strcpy(thePath, theRealPath);
      strcat(thePath, "XXXXXX");
      if (mktemp(thePath) == 0)
	{
          NSWarnMLog(@"mktemp (%s) failed - %s", thePath,
	    GSLastErrorStr(errno));
          goto failure;
	}
#endif
    }
  else
    {
#if defined(__MINGW__)
      wcscpy(wthePath,wtheRealPath);
#else
      strcpy(thePath, theRealPath);
#endif
    }

  /* Open the file (whether temp or real) for writing. */
#if defined(__MINGW__)
  theFile = _wfopen(wthePath, L"wb");
#else
  theFile = fopen(thePath, "wb");
#endif
#endif

  if (theFile == NULL)          /* Something went wrong; we weren't
                                 * even able to open the file. */
    {
#if defined(__MINGW__)
      NSWarnMLog(@"Open (%@) failed - %s",
	[NSString stringWithCharacters:wthePath length:wcslen(wthePath)],
	GSLastErrorStr(errno));
#else
      NSWarnMLog(@"Open (%s) failed - %s", thePath, GSLastErrorStr(errno));
#endif
      goto failure;
    }

  /* Now we try and write the NSData's bytes to the file.  Here `c' is
   * the number of bytes which were successfully written to the file
   * in the fwrite() call. */
  c = fwrite([self bytes], sizeof(char), [self length], theFile);

  if (c < (int)[self length])        /* We failed to write everything for
                                 * some reason. */
    {
#if defined(__MINGW__)
      NSWarnMLog(@"Fwrite (%@) failed - %s",
	[NSString stringWithCharacters:wthePath length:wcslen(wthePath)],
	GSLastErrorStr(errno));
#else
      NSWarnMLog(@"Fwrite (%s) failed - %s", thePath, GSLastErrorStr(errno));
#endif
      goto failure;
    }

  /* We're done, so close everything up. */
  c = fclose(theFile);

  if (c != 0)                   /* I can't imagine what went wrong
                                 * closing the file, but we got here,
                                 * so we need to deal with it. */
    {
#if defined(__MINGW__)
      NSWarnMLog(@"Fclose (%@) failed - %s",
	[NSString stringWithCharacters:wthePath length:wcslen(wthePath)],
	GSLastErrorStr(errno));
#else
      NSWarnMLog(@"Fclose (%s) failed - %s", thePath, GSLastErrorStr(errno));
#endif
      goto failure;
    }

  /* If we used a temporary file, we still need to rename() it be the
   * real file.  Also, we need to try to retain the file attributes of
   * the original file we are overwriting (if we are) */
  if (useAuxiliaryFile)
    {
      NSFileManager		*mgr = [NSFileManager defaultManager];
      NSMutableDictionary	*att = nil;

      if ([mgr fileExistsAtPath: path])
	{
	  att = [[mgr fileAttributesAtPath: path
			      traverseLink: YES] mutableCopy];
	  IF_NO_GC(TEST_AUTORELEASE(att));
	}

#if defined(__MINGW__)
      /*
       * The windoze implementation of the POSIX rename() function is buggy
       * and doesn't work if the destination file already exists ... so we
       * try to use a windoze specific function instead.
       */
#if 0
      if (ReplaceFile(theRealPath, thePath, 0,
	REPLACEFILE_IGNORE_MERGE_ERRORS, 0, 0) != 0)
	{
	  c = 0;
	}
      else
	{
	  c = -1;
	}
#else
      if (MoveFileEx(wthePath, wtheRealPath, MOVEFILE_REPLACE_EXISTING) != 0)
	{
	  c = 0;
	}
      else
	{
	  c = -1;
	}
#endif
#else
      c = rename(thePath, theRealPath);
#endif
      if (c != 0)               /* Many things could go wrong, I guess. */
        {
#if defined(__MINGW__)
          NSWarnMLog(@"Rename ('%@' to '%@') failed - %s",
	    [NSString stringWithCharacters:wthePath length:wcslen(wthePath)],
	    [NSString stringWithCharacters:wtheRealPath length:wcslen(wtheRealPath)],
	    GSLastErrorStr(errno));
#else
         NSWarnMLog(@"Rename ('%s' to '%s') failed - %s",
	    thePath, theRealPath, GSLastErrorStr(errno));
#endif
          goto failure;
        }

      if (att != nil)
	{
	  /*
	   * We have created a new file - so we attempt to make it's
	   * attributes match that of the original.
	   */
	  [att removeObjectForKey: NSFileSize];
	  [att removeObjectForKey: NSFileModificationDate];
	  [att removeObjectForKey: NSFileReferenceCount];
	  [att removeObjectForKey: NSFileSystemNumber];
	  [att removeObjectForKey: NSFileSystemFileNumber];
	  [att removeObjectForKey: NSFileDeviceIdentifier];
	  [att removeObjectForKey: NSFileType];
	  if ([mgr changeFileAttributes: att atPath: path] == NO)
	    {
	      NSWarnMLog(@"Unable to correctly set all attributes for '%@'",
		path);
	    }
	}
#ifndef __MINGW__
      else if (geteuid() == 0 && [@"root" isEqualToString: NSUserName()] == NO)
	{
	  att = [NSDictionary dictionaryWithObjectsAndKeys:
			NSFileOwnerAccountName, NSUserName(), nil];
	  if ([mgr changeFileAttributes: att atPath: path] == NO)
	    {
	      NSWarnMLog(@"Unable to correctly set ownership for '%@'", path);
	    }
	}
#endif
    }

  /* success: */
  return YES;

  /* Just in case the failure action needs to be changed. */
failure:
  /*
   * Attempt to tidy up by removing temporary file on failure.
   */
  if (useAuxiliaryFile)
    {
#if defined(__MINGW__)
      _wunlink(wthePath);
#else
      unlink(thePath);
#endif
    }
  return NO;
}

/**
 * Writes a copy of the contents of the receiver to the specified URL.
 */
- (BOOL) writeToURL: (NSURL*)anURL atomically: (BOOL)flag
{
  if ([anURL isFileURL] == YES)
    {
      return [self writeToFile: [anURL path] atomically: flag];
    }
  else
    {
      return [anURL setResourceData: self];
    }
}


// Deserializing Data

/**
 *  Copies data from buffer starting from cursor.  <strong>Deprecated</strong>.
 *  Use [-getBytes:] and related methods instead.
 */
- (unsigned int) deserializeAlignedBytesLengthAtCursor: (unsigned int*)cursor
{
  return (unsigned)[self deserializeIntAtCursor: cursor];
}

/**
 *  Copies data from buffer starting from cursor.  <strong>Deprecated</strong>.
 *  Use [-getBytes:] and related methods instead.
 */
- (void) deserializeBytes: (void*)buffer
		   length: (unsigned int)bytes
		 atCursor: (unsigned int*)cursor
{
  NSRange	range = { *cursor, bytes };

  [self getBytes: buffer range: range];
  *cursor += bytes;
}

- (void) deserializeDataAt: (void*)data
	        ofObjCType: (const char*)type
		  atCursor: (unsigned int*)cursor
		   context: (id <NSObjCTypeSerializationCallBack>)callback
{
  if (!type || !data)
    return;

  switch (*type)
    {
      case _C_ID:
	{
	  [callback deserializeObjectAt: data
			     ofObjCType: type
			       fromData: self
			       atCursor: cursor];
	  return;
	}
      case _C_CHARPTR:
	{
	  gss32 length;

	  [self deserializeBytes: &length
			  length: sizeof(length)
			atCursor: cursor];
	  length = GSSwapBigI32ToHost(length);
	  if (length == -1)
	    {
	      *(const char**)data = NULL;
	      return;
	    }
	  else
	    {
	      unsigned	len = (length+1)*sizeof(char);

#if	GS_WITH_GC == 0
	      *(char**)data = (char*)NSZoneMalloc(NSDefaultMallocZone(), len);
#else
	      *(char**)data = (char*)NSZoneMalloc(GSAtomicMallocZone(), len);
#endif
	      if (*(char**)data == 0)
	        {
		  [NSException raise: NSMallocException
			      format: @"out of memory to deserialize bytes"];
		}
	    }

	  [self deserializeBytes: *(char**)data
			  length: length
			atCursor: cursor];
	  (*(char**)data)[length] = '\0';
	  return;
	}
      case _C_ARY_B:
	{
	  unsigned	offset = 0;
	  unsigned	size;
	  unsigned	count = atoi(++type);
	  unsigned	i;

	  while (isdigit(*type))
	    {
	      type++;
	    }
	  size = objc_sizeof_type(type);

	  for (i = 0; i < count; i++)
	    {
	      [self deserializeDataAt: (char*)data + offset
			   ofObjCType: type
			     atCursor: cursor
			      context: callback];
	      offset += size;
	    }
	  return;
	}
      case _C_STRUCT_B:
	{
	  struct objc_struct_layout layout;

	  objc_layout_structure (type, &layout);
	  while (objc_layout_structure_next_member (&layout))
	    {
	      int		offset;
	      int		align;
	      const char	*ftype;

	      objc_layout_structure_get_info (&layout, &offset, &align, &ftype);

	      [self deserializeDataAt: ((char*)data) + offset
			   ofObjCType: ftype
			     atCursor: cursor
			      context: callback];
	    }
	  return;
        }
      case _C_PTR:
	{
	  unsigned	len = objc_sizeof_type(++type);

#if	GS_WITH_GC == 0
	  *(char**)data = (char*)NSZoneMalloc(NSDefaultMallocZone(), len);
#else
	  *(char**)data = (char*)NSZoneMalloc(GSAtomicMallocZone(), len);
#endif
	  if (*(char**)data == 0)
	    {
	      [NSException raise: NSMallocException
			  format: @"out of memory to deserialize bytes"];
	    }
	  [self deserializeDataAt: *(char**)data
		       ofObjCType: type
			 atCursor: cursor
			  context: callback];
	  return;
        }
      case _C_CHR:
      case _C_UCHR:
	{
	  [self deserializeBytes: data
			  length: sizeof(unsigned char)
			atCursor: cursor];
	  return;
	}
      case _C_SHT:
      case _C_USHT:
	{
	  unsigned short ns;

	  [self deserializeBytes: &ns
			  length: sizeof(unsigned short)
			atCursor: cursor];
	  *(unsigned short*)data = NSSwapBigShortToHost(ns);
	  return;
	}
      case _C_INT:
      case _C_UINT:
	{
	  unsigned ni;

	  [self deserializeBytes: &ni
			  length: sizeof(unsigned)
			atCursor: cursor];
	  *(unsigned*)data = NSSwapBigIntToHost(ni);
	  return;
	}
      case _C_LNG:
      case _C_ULNG:
	{
	  unsigned long nl;

	  [self deserializeBytes: &nl
			  length: sizeof(unsigned long)
			atCursor: cursor];
	  *(unsigned long*)data = NSSwapBigLongToHost(nl);
	  return;
	}
      case _C_LNG_LNG:
      case _C_ULNG_LNG:
	{
	  unsigned long long nl;

	  [self deserializeBytes: &nl
			  length: sizeof(unsigned long long)
			atCursor: cursor];
	  *(unsigned long long*)data = NSSwapBigLongLongToHost(nl);
	  return;
	}
      case _C_FLT:
	{
	  NSSwappedFloat nf;

	  [self deserializeBytes: &nf
			  length: sizeof(NSSwappedFloat)
			atCursor: cursor];
	  *(float*)data = NSSwapBigFloatToHost(nf);
	  return;
	}
      case _C_DBL:
	{
	  NSSwappedDouble nd;

	  [self deserializeBytes: &nd
			  length: sizeof(NSSwappedDouble)
			atCursor: cursor];
	  *(double*)data = NSSwapBigDoubleToHost(nd);
	  return;
	}
      case _C_CLASS:
	{
	  gsu16 ni;

	  [self deserializeBytes: &ni
			  length: sizeof(ni)
			atCursor: cursor];
	  ni = GSSwapBigI16ToHost(ni);
	  if (ni == 0)
	    {
	      *(Class*)data = 0;
	    }
	  else
	    {
	      char	name[ni+1];
	      Class	c;

	      [self deserializeBytes: name
			      length: ni
			    atCursor: cursor];
	      name[ni] = '\0';
	      c = GSClassFromName(name);
	      if (c == 0)
		{
		  NSLog(@"[%s %s] can't find class - %s",
		    GSNameFromClass([self class]),
		    GSNameFromSelector(_cmd), name);
		}
	      *(Class*)data = c;
	    }
	  return;
	}
      case _C_SEL:
	{
	  gsu16	ln;
	  gsu16	lt;

	  [self deserializeBytes: &ln
			  length: sizeof(ln)
			atCursor: cursor];
	  ln = GSSwapBigI16ToHost(ln);
	  [self deserializeBytes: &lt
			  length: sizeof(lt)
			atCursor: cursor];
	  lt = GSSwapBigI16ToHost(lt);
	  if (ln == 0)
	    {
	      *(SEL*)data = 0;
	    }
	  else
	    {
	      char	name[ln+1];
	      char	types[lt+1];
	      SEL	sel;

	      [self deserializeBytes: name
			      length: ln
			    atCursor: cursor];
	      name[ln] = '\0';
	      [self deserializeBytes: types
			      length: lt
			    atCursor: cursor];
	      types[lt] = '\0';

	      if (lt)
		{
		  sel = sel_get_typed_uid(name, types);
		}
	      else
		{
		  sel = sel_get_any_typed_uid(name);
		}
	      if (sel == 0)
		{
		  if (lt)
		    {
		      sel = sel_register_typed_name(name, types);
		    }
		  else
		    {
		      sel = sel_register_name(name);
		    }
		  if (sel == 0)
		    {
		      [NSException raise: NSInternalInconsistencyException
				  format: @"can't make sel with name '%s' "
					      @"and types '%s'", name, types];
		    }
		}
	      *(SEL*)data = sel;
	    }
	  return;
	}
      default:
	[NSException raise: NSGenericException
		    format: @"Unknown type to deserialize - '%s'", type];
    }
}

/**
 *  Retrieve an int from this data, which is assumed to be in network
 *  (big-endian) byte order.  Cursor refers to byte position.
 */
- (int) deserializeIntAtCursor: (unsigned int*)cursor
{
  unsigned ni, result;

  [self deserializeBytes: &ni length: sizeof(unsigned) atCursor: cursor];
  result = NSSwapBigIntToHost(ni);
  return result;
}

/**
 *  Retrieve an int from this data, which is assumed to be in network
 *  (big-endian) byte order.  Index refers to byte position.
 */
- (int) deserializeIntAtIndex: (unsigned int)index
{
  unsigned ni, result;

  [self deserializeBytes: &ni length: sizeof(unsigned) atCursor: &index];
  result = NSSwapBigIntToHost(ni);
  return result;
}

/**
 *  Retrieve ints from intBuffer, which is assumed to be in network (big-endian)
 *  byte order.  Count refers to number of ints, but index refers to byte
 *  position.
 */
- (void) deserializeInts: (int*)intBuffer
		   count: (unsigned int)numInts
	        atCursor: (unsigned int*)cursor
{
  unsigned i;

  [self deserializeBytes: &intBuffer
		  length: numInts * sizeof(unsigned)
		atCursor: cursor];
  for (i = 0; i < numInts; i++)
    intBuffer[i] = NSSwapBigIntToHost(intBuffer[i]);
}

/**
 *  Retrieve ints from intBuffer, which is assumed to be in network (big-endian)
 *  byte order.  Count refers to number of ints, but index refers to byte
 *  position.
 */
- (void) deserializeInts: (int*)intBuffer
		   count: (unsigned int)numInts
		 atIndex: (unsigned int)index
{
  unsigned i;

  [self deserializeBytes: &intBuffer
		  length: numInts * sizeof(int)
		atCursor: &index];
  for (i = 0; i < numInts; i++)
    {
      intBuffer[i] = NSSwapBigIntToHost(intBuffer[i]);
    }
}

- (id) copyWithZone: (NSZone*)z
{
  if (NSShouldRetainWithZone(self, z) &&
	[self isKindOfClass: [NSMutableData class]] == NO)
    return RETAIN(self);
  else
    return [[dataMalloc allocWithZone: z]
	initWithBytes: [self bytes] length: [self length]];
}

- (id) mutableCopyWithZone: (NSZone*)zone
{
  return [[mutableDataMalloc allocWithZone: zone]
	initWithBytes: [self bytes] length: [self length]];
}

- (void) encodeWithCoder: (NSCoder*)coder
{
  [coder encodeDataObject: self];
}

- (id) initWithCoder: (NSCoder*)coder
{
  id	obj = [coder decodeDataObject];

  if (obj != self)
    {
      ASSIGN(self, obj);
    }
  return self;
}

@end

/**
 *  Provides some shared-memory extensions to [NSData].
 */
@implementation	NSData (GNUstepExtensions)

/**
 *  New instance with given shared memory ID.
 */
+ (id) dataWithShmID: (int)anID length: (unsigned int)length
{
#ifdef	HAVE_SHMCTL
  NSDataShared	*d;

  d = [NSDataShared allocWithZone: NSDefaultMallocZone()];
  d = [d initWithShmID: anID length: length];
  return AUTORELEASE(d);
#else
  NSLog(@"[NSData -dataWithSmdID:length:] no shared memory support");
  return nil;
#endif
}

/**
 *  New instance with given bytes in shared memory.
 */
+ (id) dataWithSharedBytes: (const void*)bytes length: (unsigned int)length
{
  NSData	*d;

#ifdef	HAVE_SHMCTL
  d = [NSDataShared allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: bytes length: length];
#else
  d = [dataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: bytes length: length];
#endif
  return AUTORELEASE(d);
}

+ (id) dataWithStaticBytes: (const void*)bytes length: (unsigned int)length
{
  NSDataStatic	*d;

  d = [dataStatic allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytesNoCopy: (void*)bytes length: length freeWhenDone: NO];
  return AUTORELEASE(d);
}

- (void) deserializeTypeTag: (unsigned char*)tag
		andCrossRef: (unsigned int*)ref
		   atCursor: (unsigned int*)cursor
{
  [self deserializeDataAt: (void*)tag
	       ofObjCType: @encode(gsu8)
		 atCursor: cursor
		  context: nil];
  if (*tag & _GSC_MAYX)
    {
      switch (*tag & _GSC_SIZE)
	{
	  case _GSC_X_0:
	    {
	      return;
	    }
	  case _GSC_X_1:
	    {
	      gsu8	x;

	      [self deserializeDataAt: (void*)&x
			   ofObjCType: @encode(gsu8)
			     atCursor: cursor
			      context: nil];
	      *ref = (unsigned int)x;
	      return;
	    }
	  case _GSC_X_2:
	    {
	      gsu16	x;

	      [self deserializeDataAt: (void*)&x
			   ofObjCType: @encode(gsu16)
			     atCursor: cursor
			      context: nil];
	      *ref = (unsigned int)x;
	      return;
	    }
	  default:
	    {
	      gsu32	x;

	      [self deserializeDataAt: (void*)&x
			   ofObjCType: @encode(gsu32)
			     atCursor: cursor
			      context: nil];
	      *ref = (unsigned int)x;
	      return;
	    }
	}
    }
}

@end


/**
 *  Mutable version of [NSData].  Methods are provided for appending and
 *  replacing bytes in the buffer, which will be grown as needed.
 */
@implementation NSMutableData
+ (id) allocWithZone: (NSZone*)z
{
  if (self == NSMutableDataAbstract)
    {
      return NSAllocateObject(mutableDataMalloc, 0, z);
    }
  else
    {
      return NSAllocateObject(self, 0, z);
    }
}

+ (id) data
{
  NSMutableData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithCapacity: 0];
  return AUTORELEASE(d);
}

+ (id) dataWithBytes: (const void*)bytes
	      length: (unsigned int)length
{
  NSData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: bytes length: length];
  return AUTORELEASE(d);
}

+ (id) dataWithBytesNoCopy: (void*)bytes
		    length: (unsigned int)length
{
  NSData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytesNoCopy: bytes length: length];
  return AUTORELEASE(d);
}

/**
 *  New instance with buffer of given numBytes with length of valid data set
 *  to zero.  Note that capacity will be automatically increased as necessary.
 */
+ (id) dataWithCapacity: (unsigned int)numBytes
{
  NSMutableData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithCapacity: numBytes];
  return AUTORELEASE(d);
}

+ (id) dataWithContentsOfFile: (NSString*)path
{
  NSMutableData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithContentsOfFile: path];
  return AUTORELEASE(d);
}

+ (id) dataWithContentsOfMappedFile: (NSString*)path
{
  NSMutableData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithContentsOfMappedFile: path];
  return AUTORELEASE(d);
}

+ (id) dataWithContentsOfURL: (NSURL*)url
{
  NSMutableData	*d;
  NSData	*data;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  data = [url resourceDataUsingCache: YES];
  d = [d initWithBytes: [data bytes] length: [data length]];
  return AUTORELEASE(d);
}

+ (id) dataWithData: (NSData*)data
{
  NSMutableData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: [data bytes] length: [data length]];
  return AUTORELEASE(d);
}

/**
 *  New instance with buffer of capacity and valid data size equal to given
 *  length in bytes.  The buffer contents are set to zero.  The length of
 *  valid data is set to zero.  Note that buffer will be automatically
 *  increased as necessary.
 */
+ (id) dataWithLength: (unsigned int)length
{
  NSMutableData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithLength: length];
  return AUTORELEASE(d);
}

+ (id) new
{
  NSMutableData	*d;

  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithCapacity: 0];
  return d;
}

- (const void*) bytes
{
  return [self mutableBytes];
}

- (void) encodeWithCoder: (NSCoder*)aCoder
{
  unsigned	length = [self length];
  void		*bytes = [self mutableBytes];

  [aCoder encodeValueOfObjCType: @encode(unsigned long)
			     at: &length];
  if (length)
    {
      [aCoder encodeArrayOfObjCType: @encode(unsigned char)
			      count: length
				 at: bytes];
    }
}

/**
 *  Initialize with buffer capable of holding size bytes.  The length of valid
 *  data is initially set to zero.
 *  <init/>
 */
- (id) initWithCapacity: (unsigned int)capacity
{
  [self subclassResponsibility: _cmd];
  return nil;
}

- (id) initWithCoder: (NSCoder*)aCoder
{
  unsigned	l;
  NSZone	*zone;

#if	GS_WITH_GC
  zone = GSAtomicMallocZone();
#else
  zone = [self zone];
#endif

  [aCoder decodeValueOfObjCType: @encode(unsigned long) at: &l];
  if (l)
    {
      void	*b = NSZoneMalloc(zone, l);

      if (b == 0)
	{
	  NSLog(@"[NSDataMalloc -initWithCoder:] unable to get %lu bytes", l);
	  RELEASE(self);
	  return nil;
        }
      [aCoder decodeArrayOfObjCType: @encode(unsigned char) count: l at: b];
      self = [self initWithBytesNoCopy: b length: l];
    }
  else
    {
      self = [self initWithBytesNoCopy: 0 length: 0];
    }
  return self;
}

/**
 *  Initialize with buffer of capacity equal to length, and with the length
 *  of valid data set to length.  Data is set to zero.
 */
- (id) initWithLength: (unsigned int)length
{
  [self subclassResponsibility: _cmd];
  return nil;
}

// Adjusting Capacity
/**
 *  Increases buffer length by given number of bytes, filling the new space
 *  with zeros.
 */
- (void) increaseLengthBy: (unsigned int)extraLength
{
  [self setLength: [self length]+extraLength];
}

/**
 * <p>
 *   Sets the length of the NSMutableData object.
 *   If the length is increased, the newly allocated data area
 *   is filled with zero bytes.
 * </p>
 * <p>
 *   This is a 'primitive' method ... you need to implement it
 *   if you write a subclass of NSMutableData.
 * </p>
 */
- (void) setLength: (unsigned int)size
{
  [self subclassResponsibility: _cmd];
}

/**
 * <p>
 *   Returns a pointer to the data storage of the receiver.<br />
 *   Modifications to the memory pointed to by this pointer will
 *   change the contents of the object.  It is important that
 *   your code should not try to modify the memory beyond the
 *   number of bytes given by the <code>-length</code> method.
 * </p>
 * <p>
 *   NB. if the object is released, or any method that changes its
 *   size or content is called, then the pointer previously returned
 *   by this method may cease to be valid.
 * </p>
 * <p>
 *   This is a 'primitive' method ... you need to implement it
 *   if you write a subclass of NSMutableData.
 * </p>
 */
- (void*) mutableBytes
{
  [self subclassResponsibility: _cmd];
  return NULL;
}

// Appending Data

/**
 *  Appends bufferSize bytes from aBuffer to data, increasing capacity if
 *  necessary.
 */
- (void) appendBytes: (const void*)aBuffer
	      length: (unsigned int)bufferSize
{
  unsigned	oldLength = [self length];
  void*		buffer;

  [self setLength: oldLength + bufferSize];
  buffer = [self mutableBytes];
  memcpy(buffer + oldLength, aBuffer, bufferSize);
}

/**
 *  Copies and appends data from other to data, increasing capacity if
 *  necessary.
 */
- (void) appendData: (NSData*)other
{
  [self appendBytes: [other bytes] length: [other length]];
}

/**
 * Replaces the bytes of data in the specified range with a
 * copy of the new bytes supplied.<br />
 * If the location of the range specified lies beyond the end
 * of the data (<code>[self length] &lt; range.location</code>)
 * then a range exception is raised.<br />
 * Otherwise, if the range specified extends beyond the end
 * of the data, then the size of the data is increased to
 * accomodate the new bytes.<br />
 */
- (void) replaceBytesInRange: (NSRange)aRange
		   withBytes: (const void*)bytes
{
  unsigned	size = [self length];
  unsigned	need = NSMaxRange(aRange);

  if (aRange.location > size)
    {
      [NSException raise: NSRangeException
		  format: @"location bad in replaceByteInRange:withBytes:"];
    }
  if (aRange.length > 0)
    {
      if (need > size)
	{
	  [self setLength: need];
	}
      memmove([self mutableBytes] + aRange.location, bytes, aRange.length);
    }
}

/**
 * Replace the content of the receiver which lies in aRange with
 * the specified length of data from the buffer pointed to by bytes.<br />
 * The size of the receiver is adjusted to allow for the change.
 */
- (void) replaceBytesInRange: (NSRange)aRange
		   withBytes: (const void*)bytes
		      length: (unsigned int)length
{
  unsigned	size = [self length];
  unsigned	end = NSMaxRange(aRange);
  int		shift = length - aRange.length;
  unsigned	need = size + shift;
  void		*buf;

  if (aRange.location > size)
    {
      [NSException raise: NSRangeException
		  format: @"location bad in replaceByteInRange:withBytes:"];
    }
  if (need > size)
    {
      [self setLength: need];
    }
  buf = [self mutableBytes];
  if (shift < 0)
    {
      if (length > 0)
	{
	  // Copy bytes into place.
	  memmove(buf + aRange.location, bytes, length);
	}
      // Fill gap
      memmove(buf + end + shift, buf + end, size - end);
    }
  else
    {
      if (shift > 0)
	{
	  // Open space
	  memmove(buf + end + shift, buf + end, size - end);
	}
      if (length > 0)
	{
	  // Copy bytes into place.
	  memmove(buf + aRange.location, bytes, length);
	}
    }
  if (need < size)
    {
      [self setLength: need];
    }
}

/**
 *  Set bytes in aRange to 0.
 */
- (void) resetBytesInRange: (NSRange)aRange
{
  unsigned	size = [self length];

  GS_RANGE_CHECK(aRange, size);
  memset((char*)[self bytes] + aRange.location, 0, aRange.length);
}

/**
 *  Replaces contents of buffer with contents of data's buffer, increasing
 *  or shrinking capacity to match.
 */
- (void) setData: (NSData*)data
{
  NSRange	r = NSMakeRange(0, [data length]);

  [self setCapacity: r.length];
  [self replaceBytesInRange: r withBytes: [data bytes]];
}

// Serializing Data

/**
 *  Does not act as the name suggests.  Instead, serializes length itself
 *  as an int into buffer.
 */
- (void) serializeAlignedBytesLength: (unsigned int)length
{
  [self serializeInt: length];
}

- (void) serializeDataAt: (const void*)data
	      ofObjCType: (const char*)type
		 context: (id <NSObjCTypeSerializationCallBack>)callback
{
  if (!data || !type)
    return;

  switch (*type)
    {
      case _C_ID:
	[callback serializeObjectAt: (id*)data
			 ofObjCType: type
			   intoData: self];
	return;

      case _C_CHARPTR:
	{
	  gsu32	len;
	  gsu32	ni;

	  if (!*(void**)data)
	    {
	      ni = (gsu32)-1;
	      ni = GSSwapHostI32ToBig(ni);
	      [self appendBytes: (void*)&ni length: sizeof(ni)];
	      return;
	    }
	  len = (gsu32)strlen(*(void**)data);
	  ni = GSSwapHostI32ToBig(len);
	  [self appendBytes: (void*)&ni length: sizeof(ni)];
	  [self appendBytes: *(void**)data length: len];
	  return;
	}
      case _C_ARY_B:
	{
	  unsigned	offset = 0;
	  unsigned	size;
	  unsigned	count = atoi(++type);
	  unsigned	i;

	  while (isdigit(*type))
	    {
	      type++;
	    }
	  size = objc_sizeof_type(type);

	  for (i = 0; i < count; i++)
	    {
	      [self serializeDataAt: (char*)data + offset
			 ofObjCType: type
			    context: callback];
	      offset += size;
	    }
	  return;
        }
      case _C_STRUCT_B:
	{
	  struct objc_struct_layout layout;

	  objc_layout_structure (type, &layout);
	  while (objc_layout_structure_next_member (&layout))
	    {
	      int		offset;
	      int		align;
	      const char	*ftype;

	      objc_layout_structure_get_info (&layout, &offset, &align, &ftype);

	      [self serializeDataAt: ((char*)data) + offset
			 ofObjCType: ftype
			    context: callback];
	    }
	  return;
        }
      case _C_PTR:
	[self serializeDataAt: *(char**)data
		   ofObjCType: ++type
		      context: callback];
	return;
      case _C_CHR:
      case _C_UCHR:
	[self appendBytes: data length: sizeof(unsigned char)];
	return;
      case _C_SHT:
      case _C_USHT:
	{
	  unsigned short ns = NSSwapHostShortToBig(*(unsigned short*)data);
	  [self appendBytes: &ns length: sizeof(unsigned short)];
	  return;
	}
      case _C_INT:
      case _C_UINT:
	{
	  unsigned ni = NSSwapHostIntToBig(*(unsigned int*)data);
	  [self appendBytes: &ni length: sizeof(unsigned)];
	  return;
	}
      case _C_LNG:
      case _C_ULNG:
	{
	  unsigned long nl = NSSwapHostLongToBig(*(unsigned long*)data);
	  [self appendBytes: &nl length: sizeof(unsigned long)];
	  return;
	}
      case _C_LNG_LNG:
      case _C_ULNG_LNG:
	{
	  unsigned long long nl;

	  nl = NSSwapHostLongLongToBig(*(unsigned long long*)data);
	  [self appendBytes: &nl length: sizeof(unsigned long long)];
	  return;
	}
      case _C_FLT:
	{
	  NSSwappedFloat nf = NSSwapHostFloatToBig(*(float*)data);

	  [self appendBytes: &nf length: sizeof(NSSwappedFloat)];
	  return;
	}
      case _C_DBL:
	{
	  NSSwappedDouble nd = NSSwapHostDoubleToBig(*(double*)data);

	  [self appendBytes: &nd length: sizeof(NSSwappedDouble)];
	  return;
	}
      case _C_CLASS:
	{
	  const char  *name = *(Class*)data?GSNameFromClass(*(Class*)data):"";
	  gsu16	ln = (gsu16)strlen(name);
	  gsu16	ni;

	  ni = GSSwapHostI16ToBig(ln);
	  [self appendBytes: &ni length: sizeof(ni)];
	  if (ln)
	    {
	      [self appendBytes: name length: ln];
	    }
	  return;
	}
      case _C_SEL:
	{
	  const char  *name = *(SEL*)data?GSNameFromSelector(*(SEL*)data):"";
	  gsu16	ln = (name == 0) ? 0 : (gsu16)strlen(name);
	  const char  *types = *(SEL*)data?GSTypesFromSelector(*(SEL*)data):"";
	  gsu16	lt = (types == 0) ? 0 : (gsu16)strlen(types);
	  gsu16	ni;

	  ni = GSSwapHostI16ToBig(ln);
	  [self appendBytes: &ni length: sizeof(ni)];
	  ni = GSSwapHostI16ToBig(lt);
	  [self appendBytes: &ni length: sizeof(ni)];
	  if (ln)
	    {
	      [self appendBytes: name length: ln];
	    }
	  if (lt)
	    {
	      [self appendBytes: types length: lt];
	    }
	  return;
	}
      default:
	[NSException raise: NSGenericException
		    format: @"Unknown type to serialize - '%s'", type];
    }
}

/**
 * Serialize an int into this object's data buffer, swapping it to network
 * (big-endian) byte order first.
 */
- (void) serializeInt: (int)value
{
  unsigned ni = NSSwapHostIntToBig(value);
  [self appendBytes: &ni length: sizeof(unsigned)];
}

/**
 * Serialize an int into this object's data buffer at index (replacing
 * anything there currently), swapping it to network (big-endian) byte order
 * first.
 */
- (void) serializeInt: (int)value atIndex: (unsigned int)index
{
  unsigned ni = NSSwapHostIntToBig(value);
  NSRange range = { index, sizeof(int) };

  [self replaceBytesInRange: range withBytes: &ni];
}

/**
 * Serialize one or more ints into this object's data buffer, swapping them to
 * network (big-endian) byte order first.
 */
- (void) serializeInts: (int*)intBuffer
		 count: (unsigned int)numInts
{
  unsigned	i;
  SEL		sel = @selector(serializeInt:);
  IMP		imp = [self methodForSelector: sel];

  for (i = 0; i < numInts; i++)
    {
      (*imp)(self, sel, intBuffer[i]);
    }
}

/**
 * Serialize one or more ints into this object's data buffer at index
 * (replacing anything there currently), swapping them to network (big-endian)
 * byte order first.
 */
- (void) serializeInts: (int*)intBuffer
		 count: (unsigned int)numInts
	       atIndex: (unsigned int)index
{
  unsigned	i;
  SEL		sel = @selector(serializeInt:atIndex:);
  IMP		imp = [self methodForSelector: sel];

  for (i = 0; i < numInts; i++)
    {
      (*imp)(self, sel, intBuffer[i], index++);
    }
}

@end


/**
 *  Provides some additional methods to [NSData].
 */
@implementation	NSMutableData (GNUstepExtensions)

/**
 *  New instance with given shared memory ID.
 */
+ (id) dataWithShmID: (int)anID length: (unsigned int)length
{
#ifdef	HAVE_SHMCTL
  NSDataShared	*d;

  d = [NSMutableDataShared allocWithZone: NSDefaultMallocZone()];
  d = [d initWithShmID: anID length: length];
  return AUTORELEASE(d);
#else
  NSLog(@"[NSMutableData -dataWithSmdID:length:] no shared memory support");
  return nil;
#endif
}

/**
 *  New instance with given bytes in shared memory.
 */
+ (id) dataWithSharedBytes: (const void*)bytes length: (unsigned int)length
{
  NSData	*d;

#ifdef	HAVE_SHMCTL
  d = [NSMutableDataShared allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: bytes length: length];
#else
  d = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
  d = [d initWithBytes: bytes length: length];
#endif
  return AUTORELEASE(d);
}

/**
 *  Returns current capacity of data buffer.
 */
- (unsigned int) capacity
{
  [self subclassResponsibility: _cmd];
  return 0;
}

/**
 *  Sets current capacity of data buffer.  Unlike [-setLength:], this will
 *  shrink the buffer if requested.
 */
- (id) setCapacity: (unsigned int)newCapacity
{
  [self subclassResponsibility: _cmd];
  return nil;
}

/**
 *  Return shared memory ID, if using one, else -1.
 */
- (int) shmID
{
  return -1;
}

- (void) serializeTypeTag: (unsigned char)tag
{
  [self serializeDataAt: (void*)&tag
	     ofObjCType: @encode(unsigned char)
		context: nil];
}

- (void) serializeTypeTag: (unsigned char)tag
	      andCrossRef: (unsigned int)xref
{
  if (xref <= 0xff)
    {
      gsu8	x = (gsu8)xref;

      tag = (tag & ~_GSC_SIZE) | _GSC_X_1;
      [self serializeDataAt: (void*)&tag
		 ofObjCType: @encode(unsigned char)
		    context: nil];
      [self serializeDataAt: (void*)&x
		 ofObjCType: @encode(gsu8)
		    context: nil];
    }
  else if (xref <= 0xffff)
    {
      gsu16	x = (gsu16)xref;

      tag = (tag & ~_GSC_SIZE) | _GSC_X_2;
      [self serializeDataAt: (void*)&tag
		 ofObjCType: @encode(unsigned char)
		    context: nil];
      [self serializeDataAt: (void*)&x
		 ofObjCType: @encode(gsu16)
		    context: nil];
    }
  else
    {
      gsu32	x = (gsu32)xref;

      tag = (tag & ~_GSC_SIZE) | _GSC_X_4;
      [self serializeDataAt: (void*)&tag
		 ofObjCType: @encode(unsigned char)
		    context: nil];
      [self serializeDataAt: (void*)&x
		 ofObjCType: @encode(gsu32)
		    context: nil];
    }
}
@end


/*
 *	This is the top of the hierarchy of concrete implementations.
 *	As such, it contains efficient implementations of most methods.
 */
@implementation	NSDataStatic

+ (id) allocWithZone: (NSZone*)z
{
  return (NSData*)NSAllocateObject(self, 0, z);
}

/*	Creation and Destruction of objects.	*/

- (id) copy
{
  return RETAIN(self);
}

- (id) copyWithZone: (NSZone*)z
{
  return RETAIN(self);
}

- (id) mutableCopy
{
  return [[mutableDataMalloc allocWithZone: NSDefaultMallocZone()]
    initWithBytes: bytes length: length];
}

- (id) mutableCopyWithZone: (NSZone*)z
{
  return [[mutableDataMalloc allocWithZone: z]
    initWithBytes: bytes length: length];
}

- (void) dealloc
{
  bytes = 0;
  length = 0;
  [super dealloc];
}

- (id) initWithBytesNoCopy: (void*)aBuffer
		    length: (unsigned int)bufferSize
	      freeWhenDone: (BOOL)shouldFree
{
  bytes = aBuffer;
  length = bufferSize;
  return self;
}

- (Class) classForCoder
{
  return dataMalloc;		/* Will not be static data when decoded. */
}

/* Basic methods	*/

- (const void*) bytes
{
  return bytes;
}

- (void) getBytes: (void*)buffer
	    range: (NSRange)aRange
{
  GS_RANGE_CHECK(aRange, length);
  memcpy(buffer, bytes + aRange.location, aRange.length);
}

- (unsigned int) length
{
  return length;
}

static inline void
getBytes(void* dst, void* src, unsigned len, unsigned limit, unsigned *pos)
{
  if (*pos > limit || len > limit || len+*pos > limit)
    {
      [NSException raise: NSRangeException
		  format: @"Range: (%u, %u) Size: %d",
			*pos, len, limit];
    }
  memcpy(dst, src + *pos, len);
  *pos += len;
}

- (void) deserializeDataAt: (void*)data
	        ofObjCType: (const char*)type
		  atCursor: (unsigned int*)cursor
		   context: (id <NSObjCTypeSerializationCallBack>)callback
{
  if (data == 0 || type == 0)
    {
      if (data == 0)
	{
	  NSLog(@"attempt to deserialize to a null pointer");
	}
      if (type == 0)
	{
            NSLog(@"attempt to deserialize with a null type encoding");
	}
      return;
    }

  switch (*type)
    {
      case _C_ID:
	{
	  [callback deserializeObjectAt: data
			     ofObjCType: type
			       fromData: self
			       atCursor: cursor];
	  return;
	}
      case _C_CHARPTR:
	{
	  gss32 len;

	  [self deserializeBytes: &len
			  length: sizeof(len)
			atCursor: cursor];
	  len = GSSwapBigI32ToHost(len);
	  if (len == -1)
	    {
	      *(const char**)data = NULL;
	      return;
	    }
	  else
	    {
#if	GS_WITH_GC == 0
	      *(char**)data = (char*)NSZoneMalloc(NSDefaultMallocZone(), len+1);
#else
	      *(char**)data = (char*)NSZoneMalloc(GSAtomicMallocZone(), len+1);
#endif
	      if (*(char**)data == 0)
	        {
		  [NSException raise: NSMallocException
			      format: @"out of memory to deserialize bytes"];
		}
	    }
	  getBytes(*(void**)data, bytes, len, length, cursor);
	  (*(char**)data)[len] = '\0';
	  return;
	}
      case _C_ARY_B:
	{
	  unsigned	offset = 0;
	  unsigned	size;
	  unsigned	count = atoi(++type);
	  unsigned	i;

	  while (isdigit(*type))
	    {
	      type++;
	    }
	  size = objc_sizeof_type(type);

	  for (i = 0; i < count; i++)
	    {
	      [self deserializeDataAt: (char*)data + offset
			   ofObjCType: type
			     atCursor: cursor
			      context: callback];
	      offset += size;
	    }
	  return;
	}
      case _C_STRUCT_B:
	{
	  struct objc_struct_layout layout;

	  objc_layout_structure (type, &layout);
	  while (objc_layout_structure_next_member (&layout))
	    {
	      int		offset;
	      int		align;
	      const char	*ftype;

	      objc_layout_structure_get_info (&layout, &offset, &align, &ftype);

	      [self deserializeDataAt: ((char*)data) + offset
			   ofObjCType: ftype
			     atCursor: cursor
			      context: callback];
	    }
	  return;
        }
      case _C_PTR:
	{
	  unsigned	len = objc_sizeof_type(++type);

#if	GS_WITH_GC == 0
	  *(char**)data = (char*)NSZoneMalloc(NSDefaultMallocZone(), len);
#else
	  *(char**)data = (char*)NSZoneMalloc(GSAtomicMallocZone(), len);
	  if (*(char**)data == 0)
	    {
	      [NSException raise: NSMallocException
			  format: @"out of memory to deserialize bytes"];
	    }
#endif
	  [self deserializeDataAt: *(char**)data
		       ofObjCType: type
			 atCursor: cursor
			  context: callback];
	  return;
        }
      case _C_CHR:
      case _C_UCHR:
	{
	  getBytes(data, bytes, sizeof(unsigned char), length, cursor);
	  return;
	}
      case _C_SHT:
      case _C_USHT:
	{
	  unsigned short ns;

	  getBytes((void*)&ns, bytes, sizeof(ns), length, cursor);
	  *(unsigned short*)data = NSSwapBigShortToHost(ns);
	  return;
	}
      case _C_INT:
      case _C_UINT:
	{
	  unsigned ni;

	  getBytes((void*)&ni, bytes, sizeof(ni), length, cursor);
	  *(unsigned*)data = NSSwapBigIntToHost(ni);
	  return;
	}
      case _C_LNG:
      case _C_ULNG:
	{
	  unsigned long nl;

	  getBytes((void*)&nl, bytes, sizeof(nl), length, cursor);
	  *(unsigned long*)data = NSSwapBigLongToHost(nl);
	  return;
	}
      case _C_LNG_LNG:
      case _C_ULNG_LNG:
	{
	  unsigned long long nl;

	  getBytes((void*)&nl, bytes, sizeof(nl), length, cursor);
	  *(unsigned long long*)data = NSSwapBigLongLongToHost(nl);
	  return;
	}
      case _C_FLT:
	{
	  NSSwappedFloat nf;

	  getBytes((void*)&nf, bytes, sizeof(nf), length, cursor);
	  *(float*)data = NSSwapBigFloatToHost(nf);
	  return;
	}
      case _C_DBL:
	{
	  NSSwappedDouble nd;

	  getBytes((void*)&nd, bytes, sizeof(nd), length, cursor);
	  *(double*)data = NSSwapBigDoubleToHost(nd);
	  return;
	}
      case _C_CLASS:
	{
	  gsu16	ni;

	  getBytes((void*)&ni, bytes, sizeof(ni), length, cursor);
	  ni = GSSwapBigI16ToHost(ni);
	  if (ni == 0)
	    {
	      *(Class*)data = 0;
	    }
	  else
	    {
	      char	name[ni+1];
	      Class	c;

	      getBytes((void*)name, bytes, ni, length, cursor);
	      name[ni] = '\0';
	      c = GSClassFromName(name);
	      if (c == 0)
		{
		  NSLog(@"[%s %s] can't find class - %s",
		    GSNameFromClass([self class]),
		    GSNameFromSelector(_cmd), name);
		}
	      *(Class*)data = c;
	    }
	  return;
	}
      case _C_SEL:
	{
	  gsu16	ln;
	  gsu16	lt;

	  getBytes((void*)&ln, bytes, sizeof(ln), length, cursor);
	  ln = GSSwapBigI16ToHost(ln);
	  getBytes((void*)&lt, bytes, sizeof(lt), length, cursor);
	  lt = GSSwapBigI16ToHost(lt);
	  if (ln == 0)
	    {
	      *(SEL*)data = 0;
	    }
	  else
	    {
	      char	name[ln+1];
	      char	types[lt+1];
	      SEL	sel;

	      getBytes((void*)name, bytes, ln, length, cursor);
	      name[ln] = '\0';
	      getBytes((void*)types, bytes, lt, length, cursor);
	      types[lt] = '\0';

	      if (lt)
		{
		  sel = sel_get_typed_uid(name, types);
		}
	      else
		{
		  sel = sel_get_any_typed_uid(name);
		}
	      if (sel == 0)
		{
		  if (lt)
		    {
		      sel = sel_register_typed_name(name, types);
		    }
		  else
		    {
		      sel = sel_register_name(name);
		    }
		  if (sel == 0)
		    {
		      [NSException raise: NSInternalInconsistencyException
				  format: @"can't make sel with name '%s' "
					      @"and types '%s'", name, types];
		    }
		}
	      *(SEL*)data = sel;
	    }
	  return;
	}
      default:
	[NSException raise: NSGenericException
		    format: @"Unknown type to deserialize - '%s'", type];
    }
}

- (void) deserializeTypeTag: (unsigned char*)tag
		andCrossRef: (unsigned int*)ref
		   atCursor: (unsigned int*)cursor
{
  if (*cursor >= length)
    {
      [NSException raise: NSRangeException
		  format: @"Range: (%u, 1) Size: %d", *cursor, length];
    }
  *tag = *((unsigned char*)bytes + (*cursor)++);
  if (*tag & _GSC_MAYX)
    {
      switch (*tag & _GSC_SIZE)
	{
	  case _GSC_X_0:
	    {
	      return;
	    }
	  case _GSC_X_1:
	    {
	      if (*cursor >= length)
		{
		  [NSException raise: NSRangeException
			      format: @"Range: (%u, 1) Size: %d",
			  *cursor, length];
		}
	      *ref = (unsigned int)*((unsigned char*)bytes + (*cursor)++);
	      return;
	    }
	  case _GSC_X_2:
	    {
	      gsu16	x;

	      if (*cursor >= length-1)
		{
		  [NSException raise: NSRangeException
			      format: @"Range: (%u, 1) Size: %d",
			  *cursor, length];
		}
#if NEED_WORD_ALIGNMENT
	      if ((*cursor % gsu16Align) != 0)
		memcpy(&x, (bytes + *cursor), 2);
	      else
#endif
	      x = *(gsu16*)(bytes + *cursor);
	      *cursor += 2;
	      *ref = (unsigned int)GSSwapBigI16ToHost(x);
	      return;
	    }
	  default:
	    {
	      gsu32	x;

	      if (*cursor >= length-3)
		{
		  [NSException raise: NSRangeException
			      format: @"Range: (%u, 1) Size: %d",
			  *cursor, length];
		}
#if NEED_WORD_ALIGNMENT
	      if ((*cursor % gsu32Align) != 0)
		memcpy(&x, (bytes + *cursor), 4);
	      else
#endif
	      x = *(gsu32*)(bytes + *cursor);
	      *cursor += 4;
	      *ref = (unsigned int)GSSwapBigI32ToHost(x);
	      return;
	    }
	}
    }
}

@end


@implementation NSDataEmpty
- (void) dealloc
{
}
@end


@implementation	NSDataMalloc

- (id) copy
{
  if (NSShouldRetainWithZone(self, NSDefaultMallocZone()))
    return RETAIN(self);
  else
    return [[dataMalloc allocWithZone: NSDefaultMallocZone()]
      initWithBytes: bytes length: length];
}

- (id) copyWithZone: (NSZone*)z
{
  if (NSShouldRetainWithZone(self, z))
    return RETAIN(self);
  else
    return [[dataMalloc allocWithZone: z]
      initWithBytes: bytes length: length];
}

- (void) dealloc
{
  if (bytes != 0)
    {
      NSZoneFree(NSZoneFromPointer(bytes), bytes);
      bytes = 0;
    }
  [super dealloc];
}

- (id) initWithBytesNoCopy: (void*)aBuffer
		    length: (unsigned int)bufferSize
	      freeWhenDone: (BOOL)shouldFree
{
  if (shouldFree == NO)
    {
      self->isa = dataStatic;
    }
  bytes = aBuffer;
  length = bufferSize;
  return self;
}

@end

#ifdef	HAVE_MMAP
@implementation	NSDataMappedFile
+ (id) allocWithZone: (NSZone*)z
{
  return (NSData*)NSAllocateObject([NSDataMappedFile class], 0, z);
}

- (void) dealloc
{
  if (bytes != 0)
    {
      munmap(bytes, length);
      bytes = 0;
    }
  [super dealloc];
}

/**
 *  Initialize with data pointing to contents of file at path.  Bytes are
 *  only "swapped in" as needed.  File should not be moved or deleted for
 *  the life of this object.
 */
- (id) initWithContentsOfMappedFile: (NSString*)path
{
	int	fd;
	NSString *localPath = [path localFromOpenStepPath];
	
#if defined(__MINGW__)
	const unichar	*thePath = [localPath unicharString];
#else
	const char *thePath;
	thePath = [localPath fileSystemRepresentation];
#endif

	if (thePath == NULL)	
	{
		NSWarnMLog(@"Open (%@) attempt failed - bad path",localPath);
		RELEASE(self);
		return nil;
	}

	
#if defined(__MINGW__)
	fd = _wopen(thePath, _O_RDONLY);
#else
	fd = open(thePath, O_RDONLY);
#endif
	if (fd < 0)
	{
		NSWarnMLog(@"unable to open %@ - %s",localPath,GSLastErrorStr(errno));
		RELEASE(self);
		return nil;
	}
	/* Find size of file to be mapped. */
	length = lseek(fd, 0, SEEK_END);
	if (length < 0)
	{
		NSWarnMLog(@"unable to seek to eof %@ - %s",localPath,
			GSLastErrorStr(errno));
		close(fd);
		RELEASE(self);
		return nil;
	}
	/* Position at start of file. */
	if (lseek(fd, 0, SEEK_SET) != 0)
	{
		NSWarnMLog(@"unable to seek to sof %@ - %s", localPath,
			GSLastErrorStr(errno));
		close(fd);
		RELEASE(self);
		return nil;
	}
	bytes = mmap(0, length, PROT_READ, MAP_SHARED, fd, 0);
	if (bytes == MAP_FAILED)
	{
		NSWarnMLog(@"mapping failed for %s - %s",localPath, GSLastErrorStr(errno));
		close(fd);
		RELEASE(self);
		self = [dataMalloc allocWithZone: NSDefaultMallocZone()];
		self = [self initWithContentsOfFile: path];
	}
	close(fd);
	return self;
}

@end
#endif	/* HAVE_MMAP	*/

#ifdef	HAVE_SHMCTL
@implementation	NSDataShared
+ (id) allocWithZone: (NSZone*)z
{
  return (NSData*)NSAllocateObject([NSDataShared class], 0, z);
}

- (void) dealloc
{
  if (bytes != 0)
    {
      struct shmid_ds	buf;

      if (shmctl(shmid, IPC_STAT, &buf) < 0)
        NSLog(@"[NSDataShared -dealloc] shared memory control failed - %s",
		GSLastErrorStr(errno));
      else if (buf.shm_nattch == 1)
	if (shmctl(shmid, IPC_RMID, &buf) < 0)	/* Mark for deletion. */
          NSLog(@"[NSDataShared -dealloc] shared memory delete failed - %s",
		GSLastErrorStr(errno));
      if (shmdt(bytes) < 0)
        NSLog(@"[NSDataShared -dealloc] shared memory detach failed - %s",
		GSLastErrorStr(errno));
      bytes = 0;
      length = 0;
      shmid = -1;
    }
  [super dealloc];
}

- (id) initWithBytes: (const void*)aBuffer length: (unsigned int)bufferSize
{
  shmid = -1;
  if (aBuffer && bufferSize)
    {
      shmid = shmget(IPC_PRIVATE, bufferSize, IPC_CREAT|VM_RDONLY);
      if (shmid == -1)			/* Created memory? */
	{
	  NSLog(@"[-initWithBytes:length:] shared mem get failed for %u - %s",
	    bufferSize, GSLastErrorStr(errno));
	  RELEASE(self);
	  self = [dataMalloc allocWithZone: NSDefaultMallocZone()];
	  return [self initWithBytes: aBuffer length: bufferSize];
	}

    bytes = shmat(shmid, 0, 0);
    if (bytes == (void*)-1)
      {
	NSLog(@"[-initWithBytes:length:] shared mem attach failed for %u - %s",
		  bufferSize, GSLastErrorStr(errno));
	bytes = 0;
	RELEASE(self);
	self = [dataMalloc allocWithZone: NSDefaultMallocZone()];
	return [self initWithBytes: aBuffer length: bufferSize];
      }
      length = bufferSize;
    }
  return self;
}

- (id) initWithShmID: (int)anId length: (unsigned int)bufferSize
{
  struct shmid_ds	buf;

  shmid = anId;
  if (shmctl(shmid, IPC_STAT, &buf) < 0)
    {
      NSLog(@"[NSDataShared -initWithShmID:length:] shared memory control failed - %s", GSLastErrorStr(errno));
      RELEASE(self);	/* Unable to access memory. */
      return nil;
    }
  if (buf.shm_segsz < bufferSize)
    {
      NSLog(@"[NSDataShared -initWithShmID:length:] shared memory segment too small");
      RELEASE(self);	/* Memory segment too small. */
      return nil;
    }
  bytes = shmat(shmid, 0, 0);
  if (bytes == (void*)-1)
    {
      NSLog(@"[NSDataShared -initWithShmID:length:] shared memory attach failed - %s",
		GSLastErrorStr(errno));
      bytes = 0;
      RELEASE(self);	/* Unable to attach to memory. */
      return nil;
    }
  length = bufferSize;
  return self;
}

- (int) shmID
{
  return shmid;
}

@end
#endif	/* HAVE_SHMCTL	*/


@implementation	NSMutableDataMalloc
+ (void) initialize
{
  if (self == [NSMutableDataMalloc class])
    {
      GSObjCAddClassBehavior(self, [NSDataMalloc class]);
    }
}

+ (id) allocWithZone: (NSZone*)z
{
  return (NSData*)NSAllocateObject(mutableDataMalloc, 0, z);
}

- (Class) classForCoder
{
  return mutableDataMalloc;
}

- (id) copy
{
  return [[dataMalloc allocWithZone: NSDefaultMallocZone()]
    initWithBytes: bytes length: length];
}

- (id) copyWithZone: (NSZone*)z
{
  return [[dataMalloc allocWithZone: z]
    initWithBytes: bytes length: length];
}

- (void) dealloc
{
  if (bytes != 0)
    {
      if (zone != 0)
	{
	  NSZoneFree(zone, bytes);
	}
      bytes = 0;
    }
  [super dealloc];
}

- (id) initWithBytes: (const void*)aBuffer length: (unsigned int)bufferSize
{
  self = [self initWithCapacity: bufferSize];
  if (self)
    {
      if (aBuffer && bufferSize > 0)
	{
	  memcpy(bytes, aBuffer, bufferSize);
	  length = bufferSize;
	}
    }
  return self;
}

- (id) initWithBytesNoCopy: (void*)aBuffer
		    length: (unsigned int)bufferSize
	      freeWhenDone: (BOOL)shouldFree
{
  if (aBuffer == 0)
    {
      self = [self initWithCapacity: bufferSize];
      if (self != nil)
	{
	  [self setLength: bufferSize];
	}
      return self;
    }
  self = [self initWithCapacity: 0];
  if (self)
    {
      if (shouldFree == NO)
	{
	  zone = 0;		// Don't free this memory.
	}
      bytes = aBuffer;
      length = bufferSize;
      capacity = bufferSize;
      growth = capacity/2;
      if (growth == 0)
	{
	  growth = 1;
	}
    }
  return self;
}

// THIS IS THE DESIGNATED INITIALISER
/**
 *  Initialize with buffer capable of holding size bytes.
 *  <init/>
 */
- (id) initWithCapacity: (unsigned int)size
{
#if	GS_WITH_GC
  zone = GSAtomicMallocZone();
#else
  zone = GSObjCZone(self);
#endif
  if (size)
    {
      bytes = NSZoneMalloc(zone, size);
      if (bytes == 0)
	{
	  NSLog(@"[NSMutableDataMalloc -initWithCapacity:] out of memory "
	    @"for %u bytes - %s", size, GSLastErrorStr(errno));
	  RELEASE(self);
	  return nil;
	}
    }
  capacity = size;
  growth = capacity/2;
  if (growth == 0)
    {
      growth = 1;
    }
  length = 0;

  return self;
}

/**
 *  Initialize with buffer capable of holding size bytes.  Buffer is zeroed
 *  out.
 */
- (id) initWithLength: (unsigned int)size
{
  self = [self initWithCapacity: size];
  if (self)
    {
      memset(bytes, '\0', size);
      length = size;
    }
  return self;
}

- (id) initWithContentsOfFile: (NSString *)path
{
  self = [self initWithCapacity: 0];
  if (readContentsOfFile(path, &bytes, &length, zone) == NO)
    {
      DESTROY(self);
    }
  else
    {
      capacity = length;
    }
  return self;
}

- (id) initWithContentsOfMappedFile: (NSString *)path
{
  return [self initWithContentsOfFile: path];
}

- (void) appendBytes: (const void*)aBuffer
	      length: (unsigned int)bufferSize
{
  unsigned	oldLength = length;
  unsigned	minimum = length + bufferSize;

  if (minimum > capacity)
    {
      [self _grow: minimum];
    }
  memcpy(bytes + oldLength, aBuffer, bufferSize);
  length = minimum;
}

- (unsigned int) capacity
{
  return capacity;
}

- (void) _grow: (unsigned int)minimum
{
  if (minimum > capacity)
    {
      unsigned	nextCapacity = capacity + growth;
      unsigned	nextGrowth = capacity ? capacity : 1;

      while (nextCapacity < minimum)
	{
	  unsigned	tmp = nextCapacity + nextGrowth;

	  nextGrowth = nextCapacity;
	  nextCapacity = tmp;
	}
      [self setCapacity: nextCapacity];
      growth = nextGrowth;
    }
}

- (void*) mutableBytes
{
  return bytes;
}

- (void) replaceBytesInRange: (NSRange)aRange
		   withBytes: (const void*)moreBytes
{
  unsigned	need = NSMaxRange(aRange);

  if (aRange.location > length)
    {
      [NSException raise: NSRangeException
		  format: @"location bad in replaceByteInRange:withBytes:"];
    }
  if (aRange.length > 0)
    {
      if (need > length)
	{
	  [self setCapacity: need];
	  length = need;
	}
      memcpy(bytes + aRange.location, moreBytes, aRange.length);
    }
}

- (void) serializeDataAt: (const void*)data
	      ofObjCType: (const char*)type
		 context: (id <NSObjCTypeSerializationCallBack>)callback
{
  if (data == 0 || type == 0)
    {
      if (data == 0)
	{
	  NSLog(@"attempt to serialize from a null pointer");
	}
      if (type == 0)
	{
	  NSLog(@"attempt to serialize with a null type encoding");
	}
      return;
    }
  switch (*type)
    {
      case _C_ID:
	[callback serializeObjectAt: (id*)data
			 ofObjCType: type
			   intoData: self];
	return;

      case _C_CHARPTR:
	{
	  unsigned	len;
	  gss32		ni;
	  gsu32		minimum;

	  if (!*(void**)data)
	    {
	      ni = -1;
	      ni = GSSwapHostI32ToBig(ni);
	      [self appendBytes: (void*)&len length: sizeof(len)];
	      return;
	    }
	  len = strlen(*(void**)data);
	  ni = GSSwapHostI32ToBig(len);
	  minimum = length + len + sizeof(ni);
	  if (minimum > capacity)
	    {
	      [self _grow: minimum];
	    }
	  memcpy(bytes+length, &ni, sizeof(ni));
	  length += sizeof(ni);
	  if (len)
	    {
	      memcpy(bytes+length, *(void**)data, len);
	      length += len;
	    }
	  return;
	}
      case _C_ARY_B:
	{
	  unsigned	offset = 0;
	  unsigned	size;
	  unsigned	count = atoi(++type);
	  unsigned	i;
	  gsu32		minimum;

	  while (isdigit(*type))
	    {
	      type++;
	    }
	  size = objc_sizeof_type(type);

	  /*
	   *	Serialized objects are going to take up at least as much
	   *	space as the originals, so we can calculate a minimum space
	   *	we are going to need and make sure our buffer is big enough.
	   */
	  minimum = length + size*count;
	  if (minimum > capacity)
	    {
	      [self _grow: minimum];
	    }

	  for (i = 0; i < count; i++)
	    {
	      [self serializeDataAt: (char*)data + offset
			 ofObjCType: type
			    context: callback];
	      offset += size;
	    }
	  return;
	}
      case _C_STRUCT_B:
	{
	  struct objc_struct_layout layout;

	  objc_layout_structure (type, &layout);
	  while (objc_layout_structure_next_member (&layout))
	    {
	      int		offset;
	      int		align;
	      const char	*ftype;

	      objc_layout_structure_get_info (&layout, &offset, &align, &ftype);

	      [self serializeDataAt: ((char*)data) + offset
			 ofObjCType: ftype
			    context: callback];
	    }
	  return;
	}
      case _C_PTR:
	[self serializeDataAt: *(char**)data
		   ofObjCType: ++type
		      context: callback];
	return;
      case _C_CHR:
      case _C_UCHR:
	(*appendImp)(self, appendSel, data, sizeof(unsigned char));
	return;
      case _C_SHT:
      case _C_USHT:
	{
	  unsigned short ns = NSSwapHostShortToBig(*(unsigned short*)data);
	  (*appendImp)(self, appendSel, &ns, sizeof(unsigned short));
	  return;
	}
      case _C_INT:
      case _C_UINT:
	{
	  unsigned ni = NSSwapHostIntToBig(*(unsigned int*)data);
	  (*appendImp)(self, appendSel, &ni, sizeof(unsigned));
	  return;
	}
      case _C_LNG:
      case _C_ULNG:
	{
	  unsigned long nl = NSSwapHostLongToBig(*(unsigned long*)data);
	  (*appendImp)(self, appendSel, &nl, sizeof(unsigned long));
	  return;
	}
      case _C_LNG_LNG:
      case _C_ULNG_LNG:
	{
	  unsigned long long nl;

	  nl = NSSwapHostLongLongToBig(*(unsigned long long*)data);
	  (*appendImp)(self, appendSel, &nl, sizeof(unsigned long long));
	  return;
	}
      case _C_FLT:
	{
	  NSSwappedFloat nf = NSSwapHostFloatToBig(*(float*)data);
	  (*appendImp)(self, appendSel, &nf, sizeof(NSSwappedFloat));
	  return;
	}
      case _C_DBL:
	{
	  NSSwappedDouble nd = NSSwapHostDoubleToBig(*(double*)data);
	  (*appendImp)(self, appendSel, &nd, sizeof(NSSwappedDouble));
	  return;
	}
      case _C_CLASS:
	{
	  const char  *name = *(Class*)data?GSNameFromClass(*(Class*)data):"";
	  gsu16	ln = (gsu16)strlen(name);
	  gsu32	minimum = length + ln + sizeof(gsu16);
	  gsu16	ni;

	  if (minimum > capacity)
	    {
	      [self _grow: minimum];
	    }
	  ni = GSSwapHostI16ToBig(ln);
	  memcpy(bytes+length, &ni, sizeof(ni));
	  length += sizeof(ni);
	  if (ln)
	    {
	      memcpy(bytes+length, name, ln);
	      length += ln;
	    }
	  return;
	}
      case _C_SEL:
	{
	  const char  *name = *(SEL*)data?GSNameFromSelector(*(SEL*)data):"";
	  gsu16	ln = (name == 0) ? 0 : (gsu16)strlen(name);
	  const char  *types = *(SEL*)data?GSTypesFromSelector(*(SEL*)data):"";
	  gsu16	lt = (types == 0) ? 0 : (gsu16)strlen(types);
	  gsu32	minimum = length + ln + lt + 2*sizeof(gsu16);
	  gsu16	ni;

	  if (minimum > capacity)
	    {
	      [self _grow: minimum];
	    }
	  ni = GSSwapHostI16ToBig(ln);
	  memcpy(bytes+length, &ni, sizeof(ni));
	  length += sizeof(ni);
	  ni = GSSwapHostI16ToBig(lt);
	  memcpy(bytes+length, &ni, sizeof(ni));
	  length += sizeof(ni);
	  if (ln)
	    {
	      memcpy(bytes+length, name, ln);
	      length += ln;
	    }
	  if (lt)
	    {
	      memcpy(bytes+length, types, lt);
	      length += lt;
	    }
	  return;
	}
      default:
	[NSException raise: NSMallocException
		    format: @"Unknown type to serialize - '%s'", type];
    }
}

- (void) serializeTypeTag: (unsigned char)tag
{
  if (length == capacity)
    {
      [self _grow: length + 1];
    }
  ((unsigned char*)bytes)[length++] = tag;
}

- (void) serializeTypeTag: (unsigned char)tag
	      andCrossRef: (unsigned int)xref
{
  if (xref <= 0xff)
    {
      tag = (tag & ~_GSC_SIZE) | _GSC_X_1;
      if (length + 2 >= capacity)
	{
	  [self _grow: length + 2];
	}
      *(gsu8*)(bytes + length++) = tag;
      *(gsu8*)(bytes + length++) = xref;
    }
  else if (xref <= 0xffff)
    {
      gsu16	x = (gsu16)xref;

      tag = (tag & ~_GSC_SIZE) | _GSC_X_2;
      if (length + 3 >= capacity)
	{
	  [self _grow: length + 3];
	}
      *(gsu8*)(bytes + length++) = tag;
#if NEED_WORD_ALIGNMENT
      if ((length % gsu16Align) != 0)
	{
	  x = GSSwapHostI16ToBig(x);
	  memcpy((bytes + length), &x, 2);
	}
      else
#endif
      *(gsu16*)(bytes + length) = GSSwapHostI16ToBig(x);
      length += 2;
    }
  else
    {
      gsu32	x = (gsu32)xref;

      tag = (tag & ~_GSC_SIZE) | _GSC_X_4;
      if (length + 5 >= capacity)
	{
	  [self _grow: length + 5];
	}
      *(gsu8*)(bytes + length++) = tag;
#if NEED_WORD_ALIGNMENT
      if ((length % gsu32Align) != 0)
	{
	  x = GSSwapHostI32ToBig(x);
	  memcpy((bytes + length), &x, 4);
	}
      else
#endif
      *(gsu32*)(bytes + length) = GSSwapHostI32ToBig(x);
      length += 4;
    }
}

- (id) setCapacity: (unsigned int)size
{
  if (size != capacity)
    {
      void*	tmp;

      if (bytes)
	{
	  if (zone == 0)
	    {
#if	GS_WITH_GC
	      zone = GSAtomicMallocZone();
#else
	      zone = GSObjCZone(self);
#endif
	      tmp = NSZoneMalloc(zone, size);
	      if (tmp == 0)
	        {
		  [NSException raise: NSMallocException
		    format: @"Unable to set data capacity to '%d'", size];
		}
	      memcpy(tmp, bytes, capacity < size ? capacity : size);
	    }
	  else
	    {
	      tmp = NSZoneRealloc(zone, bytes, size);
	    }
	}
      else
	{
	  if (zone == 0)
	    {
#if	GS_WITH_GC
	      zone = GSAtomicMallocZone();
#else
	      zone = GSObjCZone(self);
#endif
	    }
	  tmp = NSZoneMalloc(zone, size);
	}
      if (tmp == 0)
	{
	  [NSException raise: NSMallocException
		      format: @"Unable to set data capacity to '%d'", size];
	}
      bytes = tmp;
      capacity = size;
      growth = capacity/2;
      if (growth == 0)
	{
	  growth = 1;
	}
    }
  if (size < length)
    {
      length = size;
    }
  return self;
}

- (void) setData: (NSData*)data
{
  unsigned	l = [data length];

  [self setCapacity: l];
  length = l;
  memcpy(bytes, [data bytes], length);
}

- (void) setLength: (unsigned int)size
{
  if (size > capacity)
    {
      [self setCapacity: size];
    }
  if (size > length)
    {
      memset(bytes + length, '\0', size - length);
    }
  length = size;
}

@end


#ifdef	HAVE_SHMCTL
@implementation	NSMutableDataShared
+ (id) allocWithZone: (NSZone*)z
{
  return (NSData*)NSAllocateObject([NSMutableDataShared class], 0, z);
}

- (void) dealloc
{
  if (bytes != 0)
    {
      struct shmid_ds	buf;

      if (shmctl(shmid, IPC_STAT, &buf) < 0)
	{
	  NSLog(@"[NSMutableDataShared -dealloc] shared memory "
	    @"control failed - %s", GSLastErrorStr(errno));
	}
      else if (buf.shm_nattch == 1)
	{
	  if (shmctl(shmid, IPC_RMID, &buf) < 0)	/* Mark for deletion. */
	    {
	      NSLog(@"[NSMutableDataShared -dealloc] shared memory "
		@"delete failed - %s", GSLastErrorStr(errno));
	    }
	}
      if (shmdt(bytes) < 0)
	{
	  NSLog(@"[NSMutableDataShared -dealloc] shared memory "
	    @"detach failed - %s", GSLastErrorStr(errno));
	}
      bytes = 0;
      length = 0;
      capacity = 0;
      shmid = -1;
    }
  [super dealloc];
}

- (id) initWithBytes: (const void*)aBuffer length: (unsigned int)bufferSize
{
  self = [self initWithCapacity: bufferSize];
  if (self)
    {
      if (bufferSize && aBuffer)
        memcpy(bytes, aBuffer, bufferSize);
      length = bufferSize;
    }
  return self;
}

- (id) initWithCapacity: (unsigned int)bufferSize
{
  int	e;

  shmid = shmget(IPC_PRIVATE, bufferSize, IPC_CREAT|VM_ACCESS);
  if (shmid == -1)			/* Created memory? */
    {
      NSLog(@"[NSMutableDataShared -initWithCapacity:] shared memory "
	@"get failed for %u - %s", bufferSize, GSLastErrorStr(errno));
      RELEASE(self);
      self = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
      return [self initWithCapacity: bufferSize];
    }

  bytes = shmat(shmid, 0, 0);
  e = errno;
  if (bytes == (void*)-1)
    {
      NSLog(@"[NSMutableDataShared -initWithCapacity:] shared memory "
	@"attach failed for %u - %s", bufferSize, GSLastErrorStr(e));
      bytes = 0;
      RELEASE(self);
      self = [mutableDataMalloc allocWithZone: NSDefaultMallocZone()];
      return [self initWithCapacity: bufferSize];
    }
  length = 0;
  capacity = bufferSize;

  return self;
}

- (id) initWithShmID: (int)anId length: (unsigned int)bufferSize
{
  struct shmid_ds	buf;

  shmid = anId;
  if (shmctl(shmid, IPC_STAT, &buf) < 0)
    {
      NSLog(@"[NSMutableDataShared -initWithShmID:length:] shared memory "
	@"control failed - %s", GSLastErrorStr(errno));
      RELEASE(self);	/* Unable to access memory. */
      return nil;
    }
  if (buf.shm_segsz < bufferSize)
    {
      NSLog(@"[NSMutableDataShared -initWithShmID:length:] shared memory "
	@"segment too small");
      RELEASE(self);	/* Memory segment too small. */
      return nil;
    }
  bytes = shmat(shmid, 0, 0);
  if (bytes == (void*)-1)
    {
      NSLog(@"[NSMutableDataShared -initWithShmID:length:] shared memory "
	@"attach failed - %s", GSLastErrorStr(errno));
      bytes = 0;
      RELEASE(self);	/* Unable to attach to memory. */
      return nil;
    }
  length = bufferSize;
  capacity = length;

  return self;
}

- (id) setCapacity: (unsigned int)size
{
  if (size != capacity)
    {
      void	*tmp;
      int	newid;

      newid = shmget(IPC_PRIVATE, size, IPC_CREAT|VM_ACCESS);
      if (newid == -1)			/* Created memory? */
	{
	  [NSException raise: NSMallocException
	    format: @"Unable to create shared memory segment (size:%u) - %s.",
	    size, GSLastErrorStr(errno)];
	}
      tmp = shmat(newid, 0, 0);
      if ((int)tmp == -1)			/* Attached memory? */
	{
	  [NSException raise: NSMallocException
		      format: @"Unable to attach to shared memory segment."];
	}
      memcpy(tmp, bytes, length);
      if (bytes)
	{
          struct shmid_ds	buf;

          if (shmctl(shmid, IPC_STAT, &buf) < 0)
	    {
	      NSLog(@"[NSMutableDataShared -setCapacity:] shared memory "
		@"control failed - %s", GSLastErrorStr(errno));
	    }
          else if (buf.shm_nattch == 1)
	    {
	      if (shmctl(shmid, IPC_RMID, &buf) < 0)	/* Mark for deletion. */
		{
		  NSLog(@"[NSMutableDataShared -setCapacity:] shared memory "
		    @"delete failed - %s", GSLastErrorStr(errno));
		}
	    }
	  if (shmdt(bytes) < 0)				/* Detach memory. */
	    {
              NSLog(@"[NSMutableDataShared -setCapacity:] shared memory "
		@"detach failed - %s", GSLastErrorStr(errno));
	    }
	}
      bytes = tmp;
      shmid = newid;
      capacity = size;
    }
  if (size < length)
    {
      length = size;
    }
  return self;
}

- (int) shmID
{
  return shmid;
}

@end
#endif	/* HAVE_SHMCTL	*/

