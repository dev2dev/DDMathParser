//
//  DDGroupTerm.m
//  DDMathParser
//
//  Created by Dave DeLong on 12/18/10.
//  Copyright 2010 Home. All rights reserved.
//

#import "DDGroupTerm.h"
#import "DDFunctionTerm.h"
#import "DDOperatorTerm.h"
#import "DDMathParserMacros.h"

@interface DDMathStringToken ()

- (id) initWithToken:(DDMathStringToken *)token;

@end


@interface DDFunctionTerm (DDGroupResolving)

+ (id) functionTermWithName:(NSString *)function error:(NSError **)error;

@end

@implementation DDFunctionTerm (DDGroupResolving)

+ (id) functionTermWithName:(NSString *)function error:(NSError **)error {
	DDMathStringToken * token = [DDMathStringToken mathStringTokenWithToken:function type:DDTokenTypeFunction];
	DDFunctionTerm * f = [DDFunctionTerm groupTermWithSubTerms:[NSArray array] error:error];
	[f setTokenValue:token];
	return f;
}

@end


@implementation DDGroupTerm
@synthesize subTerms;

+ (id) rootTermWithTokenizer:(DDMathStringTokenizer *)tokenizer error:(NSError **)error {
	DDGroupTerm * g = [DDGroupTerm termWithTokenizer:nil error:error];
	if (!g) { return nil; }
	
	DDMathStringToken * t = nil;
	while ((t = [tokenizer peekNextToken])) {
        DDTerm *nextTerm = [DDTerm termForTokenType:[t tokenType] withTokenizer:tokenizer error:error];
		if (!nextTerm) { return nil; }
		[[g subTerms] addObject:nextTerm];
	}
	
	return g;
}

+ (id) groupTermWithSubTerms:(NSArray *)sub error:(NSError **)error {
	DDGroupTerm * g = [[self alloc] initWithTokenizer:nil error:error];
	[[g subTerms] addObjectsFromArray:sub];
	return [g autorelease];
}

- (id) initWithTokenizer:(DDMathStringTokenizer *)tokenizer error:(NSError **)error {
	self = [super initWithTokenizer:tokenizer error:error];
	if (self) {
		subTerms = [[NSMutableArray alloc] init];
		
		if (tokenizer != nil && [self isMemberOfClass:[DDGroupTerm class]]) {
			[self setTokenValue:nil]; //we don't need no stinkin' parenthesis
			
			//TODO: find all the terms in this group
			DDMathStringToken * next = nil;
			while ((next = [tokenizer peekNextToken])) {
				if ([next operatorType] == DDOperatorParenthesisClose) { break; }
				
				DDTerm *nextTerm = [DDTerm termForTokenType:[next tokenType] withTokenizer:tokenizer error:error];
				if (!nextTerm) {
					[self release];
					return nil;
				}
				[[self subTerms] addObject:nextTerm];
			}
			
			next = [tokenizer nextToken];
			if ([next operatorType] != DDOperatorParenthesisClose) {
				if (error) {
					*error = ERR_BADARG(@"imbalanced parentheses");
				}
				[self release];
				return nil;
			}
			
		}
	}
	return self;
}

- (void) dealloc {
	[subTerms release];
	[super dealloc];
}

#pragma mark Resolving

- (NSIndexSet *) indicesOfOperatorsWithHighestPrecedence {
	NSMutableIndexSet * indices = [NSMutableIndexSet indexSet];
	DDPrecedence currentPrecedence = DDPrecedenceUnknown;
	for (NSUInteger i = 0; i < [[self subTerms] count]; ++i) {
		DDTerm * thisTerm = [[self subTerms] objectAtIndex:i];
		if ([[thisTerm tokenValue] tokenType] == DDTokenTypeOperator) {
			DDPrecedence thisPrecedence = [[thisTerm tokenValue] operatorPrecedence];
			
			if (thisPrecedence > currentPrecedence) {
				currentPrecedence = thisPrecedence;
				[indices removeAllIndexes];
				[indices addIndex:i];
			} else if (thisPrecedence == currentPrecedence) {
				[indices addIndex:i];
			}
		}
	}
	return indices;
}

#define CHECK_RANGE(_i,_f,...) if ((_i) > [terms count]) { \
if (error) { \
*error = ERR_GENERIC(_f, ##__VA_ARGS__); \
} \
return NO; \
}

- (BOOL) reduceTermsAroundOperatorAtIndex:(NSUInteger)index error:(NSError **)error {
	NSMutableArray * terms = [self subTerms];
	
	DDOperatorTerm * operator = [terms objectAtIndex:index];
	NSString * functionName = [operator operatorFunction];
	
	NSRange replacementRange = NSMakeRange(0, 0);
	DDGroupTerm * replacement = nil;
	
	//let's handle the simple stuff first:
	if ([operator operatorPrecedence] == DDPrecedenceFactorial) {
		replacementRange.location = index - 1;
		replacementRange.length = 2;
		replacement = [DDFunctionTerm functionTermWithName:functionName error:error];
		if (!replacement) { return NO; }
		[[replacement subTerms] addObject:[terms objectAtIndex:index-1]];
	} else if ([operator operatorPrecedence] == DDPrecedenceUnary) {
		CHECK_RANGE(index+2, @"no right operand to unary operator %@", [operator tokenValue]);
		replacementRange.location = index;
		replacementRange.length = 2;
		if ([[operator tokenValue] operatorType] == DDOperatorUnaryPlus) {
			//in other words, the unary + is a worthless operator:
			replacement = [terms objectAtIndex:index+1];
		} else {
			replacement = [DDFunctionTerm functionTermWithName:functionName error:error];
			if (!replacement) { return NO; }
			[[replacement subTerms] addObject:[terms objectAtIndex:index+1]];
		}
	} else {
		replacementRange.location = index - 1;
		replacementRange.length = 3;
		replacement = [DDFunctionTerm functionTermWithName:functionName error:error];
		if (!replacement) { return NO; }
		[[replacement subTerms] addObject:[terms objectAtIndex:index-1]];
		
		//special edge case where the right term of the power operator has 1+ unary operators
		//those should be evaluated before the power, even though unary has lower precedence overall
		
		NSRange rightTermRange = NSMakeRange(index+1, 1);
		CHECK_RANGE(NSMaxRange(rightTermRange), @"no right operand to binary operator %@", [operator tokenValue]);
		DDTerm * rightTerm = [terms objectAtIndex:index+1];
		while ([[rightTerm tokenValue] operatorPrecedence] == DDPrecedenceUnary) {
			rightTermRange.length++;
			CHECK_RANGE(NSMaxRange(rightTermRange), @"no right operand to unary operator");
			//-1 because the end of the range points to the term *after* the unary operator
			rightTerm = [terms objectAtIndex:(rightTermRange.location + rightTermRange.length - 1)];
		}
		if (rightTermRange.length > 1) {
			//the right term has unary operators
			NSArray * unaryExpressionTerms = [terms subarrayWithRange:rightTermRange];
			rightTerm = [DDGroupTerm groupTermWithSubTerms:unaryExpressionTerms error:error];
			if (!rightTerm) { return NO; }
			//replace the unary expression with the new term (so that replacementRange is still valid)
			[terms replaceObjectsInRange:rightTermRange withObjectsFromArray:[NSArray arrayWithObject:rightTerm]];
		}
		
		[[replacement subTerms] addObject:rightTerm];
	}
	
	if (replacement != nil) {
		[terms replaceObjectsInRange:replacementRange withObjectsFromArray:[NSArray arrayWithObject:replacement]];
	}
	return YES;
}

- (BOOL) resolveWithParser:(DDParser *)parser error:(NSError **)error {
	while ([[self subTerms] count] > 1) {
		/**
		 steps:
		 1. find the indexes of the operators with the highest precedence
		 2. if there are multiple, use [self parser] to determine which one (rightmost or leftmost)
		 3. 
		 **/
		NSIndexSet * indices = [self indicesOfOperatorsWithHighestPrecedence];
		if ([indices count] > 0) {
			NSUInteger index = [indices firstIndex];
			if ([indices count] > 1) {
				//there's more than one. do we use the rightmost or leftmost operator?
				DDOperatorTerm * operatorTerm = [[self subTerms] objectAtIndex:index];
				DDOperatorAssociativity associativity = [parser associativityForOperator:[[operatorTerm tokenValue] operatorType]];
				
				DDPrecedence operatorPrecedence = [operatorTerm operatorPrecedence];
				if (operatorPrecedence == DDPrecedenceUnary) {
					associativity = DDOperatorAssociativityRight;
				}
				if (associativity == DDOperatorAssociativityRight) {
					index = [indices lastIndex];
				}
			}
			
			//we have our operator!
			if (![self reduceTermsAroundOperatorAtIndex:index error:error]) {
				return NO;
			}
		} else {
			//there are no more operators
			//but there are 2 terms?
			//BARF!
			[NSException raise:NSGenericException format:@"invalid format: %@", [self subTerms]];
			return NO;
		}
	}
	for (DDTerm *subTerm in [self subTerms]) {
		if (![subTerm resolveWithParser:parser error:error]) {
			return NO;
		}
	}
	return YES;
}

- (NSString *) description {
	NSArray * elementDescriptions = [[self subTerms] valueForKey:@"description"];
	return [NSString stringWithFormat:@"(%@)", [elementDescriptions componentsJoinedByString:@", "]];
}

- (DDExpression *) expressionWithError:(NSError **)error {
	if ([[self subTerms] count] == 0) { return nil; }
	
	return [(DDTerm *)[[self subTerms] objectAtIndex:0] expressionWithError:error];
}

@end
