//
//  BSONCodec.m
//  BSON Codec for Objective-C.
//
//  Created by Martin Kou on 8/17/10.
//  MIT License, see LICENSE file for details.
//

#import "BSONCodec.h"
#import <ctype.h>
#import <string.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define BSONTYPE(tag,className) [className class], [NSNumber numberWithChar: (tag)]

static NSDictionary *BSONTypes()
{
	static NSDictionary *retval = nil;

	if (retval == nil)
	{
		retval = [[NSDictionary dictionaryWithObjectsAndKeys:
				  BSONTYPE(0x01, NSNumber),
				  BSONTYPE(0x02, NSString),
				  BSONTYPE(0x03, NSDictionary),
				  BSONTYPE(0x04, NSArray),
				  BSONTYPE(0x05, NSData),
				  BSONTYPE(0x08, NSNumber),
				  BSONTYPE(0x0A, NSNull),
				  BSONTYPE(0x10, NSNumber),
				  BSONTYPE(0x12, NSNumber),
				  nil] retain];
	}

	return retval;
}

#define SWAP16(x) \
	((uint16_t)((((uint16_t)(x) & 0xff00) >> 8) | \
		(((uint16_t)(x) & 0x00ff) << 8)))

#define SWAP32(x) \
	((uint32_t)((((uint32_t)(x) & 0xff000000) >> 24) | \
		(((uint32_t)(x) & 0x00ff0000) >>  8) | \
		(((uint32_t)(x) & 0x0000ff00) <<  8) | \
		(((uint32_t)(x) & 0x000000ff) << 24)))

#define SWAP64(x) \
	((uint64_t)((((uint64_t)(x) & 0xff00000000000000ULL) >> 56) | \
		(((uint64_t)(x) & 0x00ff000000000000ULL) >> 40) | \
		(((uint64_t)(x) & 0x0000ff0000000000ULL) >> 24) | \
		(((uint64_t)(x) & 0x000000ff00000000ULL) >>  8) | \
		(((uint64_t)(x) & 0x00000000ff000000ULL) <<  8) | \
		(((uint64_t)(x) & 0x0000000000ff0000ULL) << 24) | \
		(((uint64_t)(x) & 0x000000000000ff00ULL) << 40) | \
		(((uint64_t)(x) & 0x00000000000000ffULL) << 56)))


#if BYTE_ORDER == LITTLE_ENDIAN
#define BSONTOHOST16(x) (x)
#define BSONTOHOST32(x) (x)
#define BSONTOHOST64(x) (x)
#define HOSTTOBSON16(x) (x)
#define HOSTTOBSON32(x) (x)
#define HOSTTOBSON64(x) (x)

#elif BYTE_ORDER == BIG_ENDIAN
#define BSONTOHOST16(x) SWAP16(x)
#define BSONTOHOST32(x) SWAP32(x)
#define BSONTOHOST64(x) SWAP64(x)
#define HOSTTOBSON16(x) SWAP16(x)
#define HOSTTOBSON32(x) SWAP16(x)
#define HOSTTOBSON64(x) SWAP16(x)

#endif

#define CLASS_NAME_MARKER @"$$__CLASS_NAME__$$"

@implementation NSObject (BSONObjectCoding)
- (NSData *) BSONEncode
{
	if (!class_conformsToProtocol([self class], @protocol(BSONObjectCoding)))
		[NSException raise: NSInvalidArgumentException format: @"BSON encoding is only valid on objects conforming to the BSONObjectEncoding protocol."];

	id <BSONObjectCoding> myself = (id <BSONObjectCoding>) self;
	NSMutableDictionary *values = [[myself BSONDictionary] mutableCopy];

	const char* className = class_getName([self class]);
	[values setObject: [NSData dataWithBytes: (void *)className length: strlen(className)] forKey: CLASS_NAME_MARKER];
	NSData *retval = [values BSONEncode];
	[values release];

	return retval;
}

- (NSData *) BSONRepresentation
{
  return [self BSONEncode];
}
@end


@implementation NSDictionary (BSON)

- (uint8_t) BSONTypeID
{
	return 0x03;
}

- (NSData *) BSONEncode
{
	// Initialize the components structure.
	NSMutableArray *components = [[NSMutableArray alloc] init];

	NSMutableData *lengthData = [[NSMutableData alloc] initWithLength: 4];
	[components addObject: lengthData];
	[lengthData release];

	NSMutableData *contentsData = [[NSMutableData alloc] init];
	[components addObject: contentsData];
	[contentsData release];

	[components addObject: [NSData dataWithBytes: "\x00" length: 1]];

	// Ensure ordered keys. not in BSON spec, but ensures all BSONRepresentations
	// of the same dict will be the same.
	NSMutableArray *keys = [[NSMutableArray alloc] init];
	for (NSString *key in self)
		[keys addObject: key];
	[keys sortUsingSelector: @selector(caseInsensitiveCompare:)];

	// Encode data.- (NSData *) BSONEncode;
	uint8_t elementType = 0;
	for (NSString *key in keys)
	{
		NSObject *value = [self objectForKey: key];

		if ([value respondsToSelector: @selector(BSONTypeID)])
			elementType = [(id <BSONCoding>) value BSONTypeID];
		else
			elementType = 3;

		[contentsData appendBytes: &elementType length: 1];
		[contentsData appendData: [key dataUsingEncoding: NSUTF8StringEncoding]];
		[contentsData appendBytes: "\x00" length: 1];
		[contentsData appendData: [value BSONEncode]];
	}
	[keys release];

	// Write length.
	uint32_t *length = (uint32_t *)[lengthData mutableBytes];
	*length = HOSTTOBSON32([contentsData length]) + 4 + 1;

	// Assemble the output data.
	NSMutableData *retval = [NSMutableData data];
	for (NSData *data in components)
		[retval appendData: data];
	[components release];

	return retval;
}

- (NSData *) BSONRepresentation
{
  return [self BSONEncode];
}

+ (id) BSONFragment: (NSData *) data at: (const void **) base ofType: (uint8_t) t
{
	const void *current = [data bytes];
	if (base != nil)
		current = *base;
	else
		base = &current;

	uint32_t length = BSONTOHOST32(*((uint32_t *)current));
	const void *endPoint = current + length;
	current += 4;

	NSMutableDictionary *retval = [NSMutableDictionary dictionary];
	while (current < endPoint - 1)
	{
		uint8_t typeID = *((uint8_t *)current);
		current++;

		char *utf8Key = (char *) current;
		while (*((char *)current) != 0 && current < endPoint - 1)
			current++;
		current++;
		NSString *key = [NSString stringWithUTF8String: utf8Key];

		*base = current;
		Class typeClass = [BSONTypes() objectForKey: [NSNumber numberWithChar: typeID]];
		id value = objc_msgSend(typeClass, @selector(BSONFragment:at:ofType:), data, base, typeID);
		current = *base;

		[retval setObject: value forKey: key];
	}

	*base = current + 1;

	// If the dictionary has a class name marker, then it is to be converted to an object.
	if ([retval objectForKey: CLASS_NAME_MARKER] != nil)
	{
		NSData *classNameData = [retval objectForKey: CLASS_NAME_MARKER];
		char *className = malloc([classNameData length] + 1);
		memcpy(className, [classNameData bytes], [classNameData length]);
		className[[classNameData length]] = 0;

		Class targetClass = objc_getClass(className);
		if (targetClass == nil)
			[NSException raise: NSInvalidArgumentException format: @"Class %s found in incoming data is undefined.", className];

		id obj = [[targetClass alloc] initWithBSONDictionary: retval];
		return obj;
	}

	return retval;
}
@end

@implementation NSData (BSON)
- (uint8_t) BSONTypeID
{
	return 0x05;
}

- (NSData *) BSONEncode
{
	uint32_t length = HOSTTOBSON32([self length]);
	NSMutableData *retval = [NSMutableData data];
	[retval appendBytes: &length length: 4];
	[retval appendBytes: "\x00" length: 1];
	[retval appendData: self];

	return retval;
}

- (NSData *) BSONRepresentation
{
  return [self BSONEncode];
}

+ (id) BSONFragment: (NSData *) data at: (const void **) base ofType: (uint8_t) t
{
	const void *current = [data bytes];
	if (base != nil)
		current = *base;
	else
		base = &current;

	uint32_t length = BSONTOHOST32(*((uint32_t *)current));
	current += 4 + 1;

	NSData *retval = [NSData dataWithBytes: current length: length];
	current += length;
	*base = current;
	return retval;
}

- (NSDictionary *) BSONValue
{
	return [NSDictionary BSONFragment: self at: nil ofType: 0x03];
}
@end

@implementation NSNumber (BSON)
- (uint8_t) BSONTypeID
{
	const char encoding = tolower(*([self objCType]));

	switch (encoding) {
		case 'f':
		case 'd': return 0x01;
		case 'b': return 0x08;
		case 'c':
		case 's': return 0x10;
		case 'i':
			// Ok, if you're running Objective-C on 16-bit platforms...
			// Then YOU have issues.
			// So, yeah, we won't handle that case.
			if (sizeof(int) == 4)
				return 0x10;
			else if (sizeof(int) == 8)
				return 0x12;

		case 'l':
			if (sizeof(long) == 4)
				return 0x10;
			else if (sizeof(long) == 8)
				return 0x12;

		case 'q': return 0x12;
		default:
			[NSException raise: NSInvalidArgumentException format: @"%@::%s - invalid encoding type '%c'", [self class], _cmd, encoding];
	}
	return 0;
}

- (NSData *) BSONEncode
{
	const char encoding = tolower(*([self objCType]));

	if (encoding == 'd')
	{
		double value = [self doubleValue];
		return [NSData dataWithBytes: &value length: 8];
	}

	if (encoding == 'f')
	{
		double value = [self floatValue];
		return [NSData dataWithBytes: &value length: 8];
	}

	if (encoding == 'b')
	{
		char value = [self boolValue];
		return [NSData dataWithBytes: &value length: 1];
	}

	if (encoding == 'c')
	{
		int32_t value = [self charValue];
		value = HOSTTOBSON32(value);
		return [NSData dataWithBytes: &value length: 4];
	}

	if (encoding == 's')
	{
		int32_t value = [self shortValue];
		value = HOSTTOBSON32(value);
		return [NSData dataWithBytes: &value length: 4];
	}

	if (encoding == 'i')
	{
		int value = [self intValue];
		if (sizeof(int) == 4)
			value = HOSTTOBSON32(value);
		else if (sizeof(int) == 8)
			value = HOSTTOBSON64(value);
		return [NSData dataWithBytes: &value length: sizeof(int)];
	}

	if (encoding == 'l')
	{
		long value = [self longValue];
		if (sizeof(long) == 4)
			value = HOSTTOBSON32(value);
		else if (sizeof(long) == 8)
			value = HOSTTOBSON64(value);

		return [NSData dataWithBytes: &value length: sizeof(long)];
	}

	if (encoding == 'q')
	{
		long long value = HOSTTOBSON64([self longLongValue]);
		return [NSData dataWithBytes: &value length: 8];
	}

	[NSException raise: NSInvalidArgumentException format: @"%@::%s - invalid encoding type '%c'", [self class], _cmd, encoding];
	return nil;
}

- (NSData *) BSONRepresentation
{
  return [self BSONEncode];
}

+ (id) BSONFragment: (NSData *) data at: (const void **) base ofType: (uint8_t) t
{
	if (t == 0x01)
	{
		double value = ((double *) *base)[0];
		*base += 8;
		return [NSNumber numberWithDouble: value];
	}

	if (t == 0x08)
	{
		char value = ((char *) *base)[0];
		*base += 1;
		return [NSNumber numberWithBool: value];
	}

	if (t == 0x10)
	{
		int32_t value = BSONTOHOST32(((int32_t *) *base)[0]);
		*base += 4;

		if (sizeof(int) == 4)
			return [NSNumber numberWithInt: value];

		return [NSNumber numberWithLong: value];
	}

	if (t == 0x12)
	{
		int64_t value = BSONTOHOST64(((int64_t *) *base)[0]);
		*base += 8;

		return [NSNumber numberWithLongLong: value];
	}

	return nil;
}
@end

@implementation NSString (BSON)
- (uint8_t) BSONTypeID
{
	return 0x02;
}

- (NSData *) BSONEncode
{
	NSData *utf8Data = [self dataUsingEncoding: NSUTF8StringEncoding];
	uint32_t length = HOSTTOBSON32([utf8Data length] + 1);

	NSMutableData *retval = [NSMutableData data];
	[retval appendBytes: &length length: 4];
	[retval appendData: utf8Data];
	[retval appendBytes: "\x00" length: 1];
	return retval;
}

- (NSData *) BSONRepresentation
{
  return [self BSONEncode];
}

+ (id) BSONFragment: (NSData *) data at: (const void **) base ofType: (uint8_t) typeID
{
	uint32_t length = BSONTOHOST32(((const uint32_t *) *base)[0]);
	*base += 4;

	const char *utf8Str = (const char *) *base;
	*base += length;

	return [NSString stringWithUTF8String: utf8Str];
}
@end

@implementation NSArray (BSON)
- (uint8_t) BSONTypeID
{
	return 0x04;
}

- (NSData *) BSONEncode
{
	// Initialize the components structure.
	NSMutableArray *components = [[NSMutableArray alloc] init];
	
	NSMutableData *lengthData = [[NSMutableData alloc] initWithLength: 4];
	[components addObject: lengthData];
	[lengthData release];
	
	NSMutableData *contentsData = [[NSMutableData alloc] init];
	[components addObject: contentsData];
	[contentsData release];
	
	[components addObject: [NSData dataWithBytes: "\x00" length: 1]];
	
	// Encode data.
	uint8_t elementType = 0;
	int count = [self count];
	for (int i = 0 ; i < count ; i++)
	{
		NSObject *value = [self objectAtIndex: i];
		
		if ([value respondsToSelector: @selector(BSONTypeID)])
			elementType = [(id <BSONCoding>) value BSONTypeID];
		else
			elementType = 3;
		
		[contentsData appendBytes: &elementType length: 1];
		[contentsData appendData: [[NSString stringWithFormat: @"%d", i] dataUsingEncoding: NSUTF8StringEncoding]];
		[contentsData appendBytes: "\x00" length: 1];
		[contentsData appendData: [value BSONEncode]];
	}
	
	// Write length.
	uint32_t *length = (uint32_t *)[lengthData mutableBytes];
	*length = HOSTTOBSON32([contentsData length]) + 4 + 1;
	
	// Assemble the output data.
	NSMutableData *retval = [NSMutableData data];
	for (NSData *data in components)
		[retval appendData: data];
	[components release];
	
	return retval;
}

- (NSData *) BSONRepresentation
{
  return [self BSONEncode];
}

+ (id) BSONFragment: (NSData *) data at: (const void **) base ofType: (uint8_t) typeID
{
	NSDictionary *tmp = [NSDictionary BSONFragment: data at: base ofType: 0x03];
	NSMutableArray *retval = [NSMutableArray arrayWithCapacity: [tmp count]];
	for (int i = 0; i < [tmp count]; i++)
		[retval addObject: [tmp objectForKey: [NSString stringWithFormat: @"%d", i]]];

	return retval;
}
@end

@implementation NSNull (BSON)
- (uint8_t) BSONTypeID
{
	return 0x0a;
}

- (NSData *) BSONEncode
{
	return [NSData dataWithBytes: "" length: 0];
}

- (NSData *) BSONRepresentation
{
  return [self BSONEncode];
}

+ (id) BSONFragment: (NSData *) data at: (const void **) base ofType: (uint8_t) typeID
{
	return [NSNull null];
}
@end
