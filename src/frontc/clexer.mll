(*
 *
 * Copyright (c) 2001-2003,
 *  George C. Necula    <necula@cs.berkeley.edu>
 *  Scott McPeak        <smcpeak@cs.berkeley.edu>
 *  Wes Weimer          <weimer@cs.berkeley.edu>
 *  Ben Liblit          <liblit@cs.berkeley.edu>
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * 3. The names of the contributors may not be used to endorse or promote
 * products derived from this software without specific prior written
 * permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
 * IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
 * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *)
(* FrontC -- lexical analyzer
**
** 1.0	3.22.99	Hugues Cass�	First version.
** 2.0  George Necula 12/12/00: Many extensions
*)
{
open Cparser
exception Eof
exception InternalError of string
module E = Errormsg
module H = Hashtbl

let currentLoc () = 
  let l, f, c = E.getPosition () in
  { Cabs.lineno   = l;
    Cabs.filename = f;
    Cabs.byteno   = c; }

(*
** Keyword hashtable
*)
let lexicon = H.create 211
let init_lexicon _ =
  H.clear lexicon;
  List.iter 
    (fun (key, builder) -> H.add lexicon key builder)
    [ ("auto", fun loc -> AUTO loc);
      ("const", fun loc -> CONST loc);
      ("__const", fun loc -> CONST loc);
      ("__const__", fun loc -> CONST loc);
      ("static", fun loc -> STATIC loc);
      ("extern", fun loc -> EXTERN loc);
      ("long", fun loc -> LONG loc);
      ("short", fun loc -> SHORT loc);
      ("register", fun loc -> REGISTER loc);
      ("signed", fun loc -> SIGNED loc);
      ("__signed", fun loc -> SIGNED loc);
      ("unsigned", fun loc -> UNSIGNED loc);
      ("volatile", fun loc -> VOLATILE loc);
      ("__volatile", fun loc -> VOLATILE loc);
      (* WW: see /usr/include/sys/cdefs.h for why __signed and __volatile
       * are accepted GCC-isms *)
      ("char", fun loc -> CHAR loc);
      ("int", fun loc -> INT loc);
      ("float", fun loc -> FLOAT loc);
      ("double", fun loc -> DOUBLE loc);
      ("void", fun loc -> VOID loc);
      ("enum", fun loc -> ENUM loc);
      ("struct", fun loc -> STRUCT loc);
      ("typedef", fun loc -> TYPEDEF loc);
      ("union", fun loc -> UNION loc);
      ("break", fun loc -> BREAK loc);
      ("continue", fun loc -> CONTINUE loc);
      ("goto", fun loc -> GOTO loc); 
      ("return", fun loc -> RETURN loc);
      ("switch", fun loc -> SWITCH loc);
      ("case", fun loc -> CASE loc); 
      ("default", fun loc -> DEFAULT loc);
      ("while", fun loc -> WHILE loc);  
      ("do", fun loc -> DO loc);  
      ("for", fun loc -> FOR loc);
      ("if", fun loc -> IF loc);
      ("else", fun _ -> ELSE);
      (*** Implementation specific keywords ***)
      ("__signed__", fun loc -> SIGNED loc);
      ("__inline__", fun loc -> INLINE loc);
      ("inline", fun loc -> INLINE loc); 
      ("__inline", fun loc -> INLINE loc);
      ("_inline", fun loc -> INLINE loc);
      ("__attribute__", fun loc -> ATTRIBUTE loc);
      ("__attribute", fun loc -> ATTRIBUTE loc);
      ("__blockattribute__", fun _ -> BLOCKATTRIBUTE);
      ("__blockattribute", fun _ -> BLOCKATTRIBUTE);
      ("__asm__", fun loc -> ASM loc);
      ("asm", fun loc -> ASM loc);
      ("__typeof__", fun loc -> TYPEOF loc);
      ("__typeof", fun loc -> TYPEOF loc);
      ("typeof", fun loc -> TYPEOF loc); 
      ("__alignof", fun loc -> ALIGNOF loc);
      ("__alignof__", fun loc -> ALIGNOF loc);
      ("__volatile__", fun loc -> VOLATILE loc);
      ("__volatile", fun loc -> VOLATILE loc);

      ("__FUNCTION__", fun loc -> FUNCTION__ loc);
      ("__func__", fun loc -> FUNCTION__ loc); (* ISO 6.4.2.2 *)
      ("__PRETTY_FUNCTION__", fun loc -> PRETTY_FUNCTION__ loc);
      ("__label__", fun _ -> LABEL__);
      (*** weimer: GCC arcana ***)
      ("__restrict", fun loc -> RESTRICT loc);
      ("restrict", fun loc -> RESTRICT loc);
(*      ("__extension__", EXTENSION); *)
      (**** MS VC ***)
      ("__int64", fun _ -> INT64 (currentLoc ()));
      ("__int32", fun loc -> INT loc);
      ("_cdecl",  fun _ -> MSATTR ("_cdecl", currentLoc ())); 
      ("__cdecl", fun _ -> MSATTR ("__cdecl", currentLoc ()));
      ("_stdcall", fun _ -> MSATTR ("_stdcall", currentLoc ())); 
      ("__stdcall", fun _ -> MSATTR ("__stdcall", currentLoc ()));
      ("_fastcall", fun _ -> MSATTR ("_fastcall", currentLoc ())); 
      ("__fastcall", fun _ -> MSATTR ("__fastcall", currentLoc ()));
      ("__declspec", fun loc -> DECLSPEC loc);
      (* weimer: some files produced by 'GCC -E' expect this type to be
       * defined *)
      ("__builtin_va_list", 
       fun _ -> NAMED_TYPE ("__builtin_va_list", currentLoc ()));
      ("__builtin_va_arg", fun loc -> BUILTIN_VA_ARG loc);
    ]

(* Mark an identifier as a type name. The old mapping is preserved and will 
 * be reinstated when we exit this context *)
let add_type name =
   (* ignore (print_string ("adding type name " ^ name ^ "\n"));  *)
   H.add lexicon name (fun loc -> NAMED_TYPE (name, loc))

let context : string list list ref = ref []

let push_context _ = context := []::!context

let pop_context _ = 
  match !context with
    [] -> raise (InternalError "Empty context stack")
  | con::sub ->
		(context := sub;
		List.iter (fun name -> 
                           (* ignore (print_string ("removing lexicon for " ^ name ^ "\n")); *)
                            H.remove lexicon name) con)

(* Mark an identifier as a variable name. The old mapping is preserved and 
 * will be reinstated when we exit this context  *)
let add_identifier name =
  match !context with
    [] -> () (* Just ignore raise (InternalError "Empty context stack") *)
  | con::sub ->
      (context := (name::con)::sub;
       (*                print_string ("adding IDENT for " ^ name ^ "\n"); *)
       H.add lexicon name (fun loc -> IDENT (name, loc)))


(*
** Useful primitives
*)
let scan_ident id =
  let here = currentLoc () in
  try (H.find lexicon id) here
  (* default to variable name, as opposed to type *)
  with Not_found -> IDENT (id, here)


(*
** Buffer processor
*)
 
let attribDepth = ref 0 (* Remembers the nesting level when parsing 
                         * attributes *)


let init ~(filename: string) : Lexing.lexbuf =
  attribDepth := 0;
  init_lexicon ();
  (* Inititialize the pointer in Errormsg *)
  E.add_type := add_type;
  E.push_context := push_context;
  E.pop_context := pop_context;
  E.add_identifier := add_identifier;
  E.startParsing (E.ParseFile filename)


let finish () = 
  E.finishParsing ()

(*** Error handling ***)
let error msg =
  E.parse_error msg (Parsing.symbol_start ()) (Parsing.symbol_end ());
  raise Parsing.Parse_error


(*** escape character management ***)
let scan_escape str =
  match str with
    "n" -> '\n'
  | "r" -> '\r'
  | "t" -> '\t'
  | "b" -> '\b'
  | "f" -> '\012'  (* ASCII code 12 *)
  | "v" -> '\011'  (* ASCII code 11 *)
  | "a" -> '\007'  (* ASCII code 7 *)
  | "e" -> '\027'  (* ASCII code 27. This is a GCC extension *)
  | "'" -> '\''    
  | "\""-> '"'     (* '"' *)
  | "?" -> '?'
  | "\\" -> '\\' 
  | _ -> error ("Unrecognized escape sequence: \\" ^ str)

let scan_hex_escape str =
  let radix = Int64.of_int 16 in
  let the_value = ref Int64.zero in
  (* start at character 2 to skip the \x *)
  for i = 2 to (String.length str) - 1 do
    let thisDigit = Cabs.valueOfDigit (String.get str i) in
    (* the_value := !the_value * 16 + thisDigit *)
    the_value := Int64.add (Int64.mul !the_value radix) thisDigit
  done;
  !the_value

let scan_oct_escape str =
  let radix = Int64.of_int 8 in
  let the_value = ref Int64.zero in
  (* start at character 1 to skip the \x *)
  for i = 1 to (String.length str) - 1 do
    let thisDigit = Cabs.valueOfDigit (String.get str i) in
    (* the_value := !the_value * 8 + thisDigit *)
    the_value := Int64.add (Int64.mul !the_value radix) thisDigit
  done;
  !the_value

let make_char (i:int64):char =
  let min_val = Int64.zero in
  let max_val = Int64.of_int 255 in
  (* if i < 0 || i > 255 then error*)
  if compare i min_val < 0 || compare i max_val > 0 then begin
    let msg = Printf.sprintf "character 0x%Lx too big" i in
    error msg
  end;
  Char.chr (Int64.to_int i)


(* ISO standard locale-specific function to convert a wide character
 * into a sequence of normal characters. Here we work on strings. 
 * We convert L"Hi" to "H\000i\000" 
  matth: this seems unused.
let wbtowc wstr =
  let len = String.length wstr in 
  let dest = String.make (len * 2) '\000' in 
  for i = 0 to len-1 do 
    dest.[i*2] <- wstr.[i] ;
  done ;
  dest
*)

(* This function converst the "Hi" in L"Hi" to { L'H', L'i', L'\0' }
  matth: this seems unused.
let wstr_to_warray wstr =
  let len = String.length wstr in
  let res = ref "{ " in
  for i = 0 to len-1 do
    res := !res ^ (Printf.sprintf "L'%c', " wstr.[i])
  done ;
  res := !res ^ "}" ;
  !res
*)
}

let decdigit = ['0'-'9']
let octdigit = ['0'-'7']
let hexdigit = ['0'-'9' 'a'-'f' 'A'-'F']
let letter = ['a'- 'z' 'A'-'Z']


let usuffix = ['u' 'U']
let lsuffix = "l"|"L"|"ll"|"LL"
let intsuffix = lsuffix | usuffix | usuffix lsuffix | lsuffix usuffix

let hexprefix = '0' ['x' 'X']

let intnum = decdigit+ intsuffix?
let octnum = '0' octdigit+ intsuffix?
let hexnum = hexprefix hexdigit+ intsuffix?

let exponent = ['e' 'E']['+' '-']? decdigit+
let fraction  = '.' decdigit+
let decfloat = (intnum? fraction)
	      |(intnum exponent)
	      |(intnum? fraction exponent)
	      | (intnum '.') 
              | (intnum '.' exponent) 

let hexfraction = hexdigit* '.' hexdigit+ | hexdigit+
let binexponent = ['p' 'P'] ['+' '-']? decdigit+
let hexfloat = hexprefix hexfraction binexponent
             | hexprefix hexdigit+   binexponent

let floatsuffix = ['f' 'F' 'l' 'L']
let floatnum = (decfloat | hexfloat) floatsuffix?

let ident = (letter|'_')(letter|decdigit|'_')* 
let attribident = (letter|'_')(letter|decdigit|'_'|':')
let blank = [' ' '\t' '\012' '\r']+
let escape = '\\' _
let hex_escape = '\\' ['x' 'X'] hexdigit+
let oct_escape = '\\' octdigit octdigit? octdigit? 

rule initial =
	parse 	"/*"			{ let _ = comment lexbuf in 
                                          initial lexbuf}
|               "//"                    { endline lexbuf }
|		blank			{initial lexbuf}
|               '\n'                    { E.newline (); initial lexbuf }
|		'#'			{ hash lexbuf}
|               "_Pragma" 	        { PRAGMA (currentLoc ()) }
|		'\''			{ CST_CHAR (chr lexbuf, currentLoc ())}
|		"L'"			{ (* weimer: wide character constant *)
                                          let wcc = chr lexbuf in 
                                          CST_CHAR (wcc, currentLoc ()) }
|		'"'			{ (* '"' *)
(* matth: BUG:  this could be either a regular string or a wide string.
 *  e.g. if it's the "world" in 
 *     L"Hello, " "world"
 *  then it should be treated as wide even though there's no L immediately
 *  preceding it.  See test/small1/wchar5.c for a failure case. *)
                                          try CST_STRING (str lexbuf, currentLoc ())
                                          with e -> 
                                             raise (InternalError 
                                                     ("str: " ^ 
                                                      Printexc.to_string e))}
|		"L\""			{ (* weimer: wchar_t string literal *)
                                          try CST_WSTRING(wstr lexbuf, currentLoc ())
                                          with e -> 
                                             raise (InternalError 
                                                     ("wide string: " ^ 
                                                      Printexc.to_string e))}
|		floatnum		{CST_FLOAT (Lexing.lexeme lexbuf, currentLoc ())}
|		hexnum			{CST_INT (Lexing.lexeme lexbuf, currentLoc ())}
|		octnum			{CST_INT (Lexing.lexeme lexbuf, currentLoc ())}
|		intnum			{CST_INT (Lexing.lexeme lexbuf, currentLoc ())}
|		"!quit!"		{EOF}
|		"..."			{ELLIPSIS}
|		"+="			{PLUS_EQ}
|		"-="			{MINUS_EQ}
|		"*="			{STAR_EQ}
|		"/="			{SLASH_EQ}
|		"%="			{PERCENT_EQ}
|		"|="			{PIPE_EQ}
|		"&="			{AND_EQ}
|		"^="			{CIRC_EQ}
|		"<<="			{INF_INF_EQ}
|		">>="			{SUP_SUP_EQ}
|		"<<"			{INF_INF}
|		">>"			{SUP_SUP}
| 		"=="			{EQ_EQ}
| 		"!="			{EXCLAM_EQ}
|		"<="			{INF_EQ}
|		">="			{SUP_EQ}
|		"="				{EQ}
|		"<"				{INF}
|		">"				{SUP}
|		"++"			{PLUS_PLUS (currentLoc ())}
|		"--"			{MINUS_MINUS (currentLoc ())}
|		"->"			{ARROW}
|		'+'				{PLUS (currentLoc ())}
|		'-'				{MINUS (currentLoc ())}
|		'*'				{STAR (currentLoc ())}
|		'/'				{SLASH}
|		'%'				{PERCENT}
|		'!'				{EXCLAM (currentLoc ())}
|		"&&"			{AND_AND (currentLoc ())}
|		"||"			{PIPE_PIPE}
|		'&'				{AND (currentLoc ())}
|		'|'				{PIPE}
|		'^'				{CIRC}
|		'?'				{QUEST}
|		':'				{COLON}
|		'~'				{TILDE (currentLoc ())}
	
|		'{'				{LBRACE (currentLoc ())}
|		'}'				{RBRACE (currentLoc ())}
|		'['				{LBRACKET}
|		']'				{RBRACKET}
|		'('				{LPAREN (currentLoc ())}
|		')'				{RPAREN}
|		';'				{SEMICOLON (currentLoc ())}
|		','				{COMMA}
|		'.'				{DOT}
|		"sizeof"		{SIZEOF (currentLoc ())}
|               "__asm"                 { if !Cprint.msvcMode then 
                                             MSASM (msasm lexbuf, currentLoc ()) 
                                          else (ASM (currentLoc ())) }
      
(* sm: tree transformation keywords *)
|               "@transform"            {AT_TRANSFORM (currentLoc ())}
|               "@transformExpr"        {AT_TRANSFORMEXPR (currentLoc ())}
|               "@specifier"            {AT_SPECIFIER (currentLoc ())}
|               "@expr"                 {AT_EXPR (currentLoc ())}
|               "@name"                 {AT_NAME}

(* __extension__ is a black. The parser runs into some conflicts if we let it
 * pass *)
|               "__extension__"         {initial lexbuf }
|		ident			{scan_ident (Lexing.lexeme lexbuf)}
|		eof			{EOF}
|		_			{E.parse_error
						"Invalid symbol"
						(Lexing.lexeme_start lexbuf)
						(Lexing.lexeme_end lexbuf);
						initial lexbuf}
and comment =
    parse 	
      "*/"			        { () }
|     '\n'                              { E.newline (); comment lexbuf }
| 		_ 			{ comment lexbuf }

(* # <line number> <file name> ... *)
and hash = parse
  '\n'		{ E.newline (); initial lexbuf}
| blank		{ hash lexbuf}
| intnum	{ (* We are seeing a line number. This is the number for the 
                   * next line *)
                  E.setCurrentLine (int_of_string (Lexing.lexeme lexbuf) - 1);
                  (* A file name must follow *)
		  file lexbuf }
| "line"        { hash lexbuf } (* MSVC line number info *)
| "pragma"      { PRAGMA (currentLoc ()) }
| _	        { endline lexbuf}

and file =  parse 
        '\n'		        {E.newline (); initial lexbuf}
|	blank			{file lexbuf}
|	'"' [^ '\012' '\t' '"']* '"' 	{ (* '"' *)
                                   let n = Lexing.lexeme lexbuf in
                                   let n1 = String.sub n 1 
                                       ((String.length n) - 2) in
                                   E.setCurrentFile n1;
				 endline lexbuf}

|	_			{endline lexbuf}

and endline = parse 
        '\n' 			{ E.newline (); initial lexbuf}
|	_			{ endline lexbuf}

and pragma = parse
   '\n'                 { E.newline (); "" }
|   _                   { let cur = Lexing.lexeme lexbuf in 
                          cur ^ (pragma lexbuf) }  

and str = parse
        '"'             {[]} (* no nul terminiation in CST_STRING *)

|	hex_escape	{let cur = scan_hex_escape(Lexing.lexeme lexbuf) in
                                         cur :: (str lexbuf)}
|	oct_escape	{let cur = scan_oct_escape (Lexing.lexeme lexbuf) in 
                                         cur :: (str lexbuf)}
|	"\\0"		{Int64.zero :: (str lexbuf)}
|	escape		{let cur = scan_escape (String.sub
					  (Lexing.lexeme lexbuf) 1 1) in 
                         Int64.of_int (Char.code cur) :: (str lexbuf)}
|	_		{let cur: int64 list = Cabs.explodeStringToInts
                                                (Lexing.lexeme lexbuf) in 
                           cur @ (str lexbuf)} 

and wstr = parse
        '"'             {[]} (* no nul terminiation in CST_WSTRING *)

|	hex_escape	{let cur = scan_hex_escape (Lexing.lexeme lexbuf) in 
                                        cur :: (wstr lexbuf)}
|	oct_escape	{let cur = scan_oct_escape (Lexing.lexeme lexbuf) in 
                                         cur :: (wstr lexbuf)}
|	"\\0"		{Int64.zero :: (wstr lexbuf)}
|	escape		{let cur:char = scan_escape (String.sub
					  (Lexing.lexeme lexbuf) 1 1) in 
                           Int64.of_int (Char.code cur) :: (wstr lexbuf)}
|	_		{let cur: int64 list = Cabs.explodeStringToInts
                                                (Lexing.lexeme lexbuf) in 
                           cur @ (wstr lexbuf)} 

and chr =  parse
    '\''	        {""}
(*matth: we evaluate hex and oct escapes in cabs2cil.  *)
|	hex_escape	{let cur = Lexing.lexeme lexbuf in cur ^ (chr lexbuf)}
|	oct_escape	{let cur = Lexing.lexeme lexbuf in cur ^ (chr lexbuf)}
|	"\\0"		{(String.make 1 (Char.chr 0)) ^ (chr lexbuf)}
|	escape		{let cur = scan_escape (String.sub
					  (Lexing.lexeme lexbuf) 1 1) in 
                         let cur': string = String.make 1 cur in
                                            cur' ^ (chr lexbuf)}
|   _			{let cur = Lexing.lexeme lexbuf in cur ^ (chr lexbuf)} 
	
and msasm = parse
    blank               { msasm lexbuf }
|   '{'                 { msasminbrace lexbuf }
|   _                   { let cur = Lexing.lexeme lexbuf in 
                          cur ^ (msasmnobrace lexbuf) }

and msasminbrace = parse
    '}'                 { "" }
|   _                   { let cur = Lexing.lexeme lexbuf in 
                          cur ^ (msasminbrace lexbuf) }  
and msasmnobrace = parse
   ['}' ';' '\n']       { lexbuf.Lexing.lex_curr_pos <- 
                               lexbuf.Lexing.lex_curr_pos - 1;
                          "" }
|  "__asm"              { lexbuf.Lexing.lex_curr_pos <- 
                               lexbuf.Lexing.lex_curr_pos - 5;
                          "" }
|  _                    { let cur = Lexing.lexeme lexbuf in 

                          cur ^ (msasmnobrace lexbuf) }

and attribute = parse
   '\n'                 { E.newline (); attribute lexbuf }
|  blank                { attribute lexbuf }
|  '('                  { incr attribDepth; LPAREN (currentLoc ()) }
|  ')'                  { decr attribDepth;
                          if !attribDepth = 0 then
                            initial lexbuf (* Skip the last closed paren *)
                          else
                            RPAREN }
|  attribident          { IDENT (Lexing.lexeme lexbuf, currentLoc ()) }

|  '\''			{ CST_CHAR (chr lexbuf, currentLoc ())}
|  '"'			{ (* '"' *)
                                          try CST_STRING (str lexbuf, currentLoc ())
                                          with e -> 
                                             raise (InternalError "str")}
|  floatnum		{CST_FLOAT (Lexing.lexeme lexbuf, currentLoc ())}
|  hexnum		{CST_INT (Lexing.lexeme lexbuf, currentLoc ())}
|  octnum		{CST_INT (Lexing.lexeme lexbuf, currentLoc ())}
|  intnum		{CST_INT (Lexing.lexeme lexbuf, currentLoc ())}


{

}
