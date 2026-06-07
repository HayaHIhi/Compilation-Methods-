%{
#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <sstream>
#include <fstream>
#include "part3_helpers.hpp"

using namespace std;

extern int yylex();
extern int line_number; // Matches definition in part1.lex
extern char* yytext;
extern FILE* yyin;
void yyerror(const char* s);

// --- Global Compile-Time State ---
int currentScopeDepth = 0;
int currentStackOffset = 0; 
int regIdxInt = 20;   
int regIdxFloat = 20; 

int stackFrameSizePlaceholderLine = 0; // Track where to insert stack frame size

int nextReg(Type t) {
    if (t == float_) return regIdxFloat++;
    return regIdxInt++;
}

// Current Function Context
string currentFuncName = "";
Type currentFuncType = void_t;

// --- Symbol Table ---
void addSymbol(string name, Type t) {
    // cerr << "DEBUG: addSymbol(" << name << ") at depth " << currentScopeDepth << endl;
    if (symbolTable.find(name) != symbolTable.end()) {
        if (symbolTable[name].depth == currentScopeDepth) {
            cerr << "Semantic error: Variable already declared in line number " << line_number << endl;
            exit(SEMANTIC_ERROR);
        }
        // Shadowing: Add new entry to the existing symbol's maps
        symbolTable[name].type[currentScopeDepth] = t;
        symbolTable[name].offset[currentScopeDepth] = currentStackOffset;
        symbolTable[name].depth = currentScopeDepth;
    } else {
        // New Symbol
        Symbol s;
        s.type[currentScopeDepth] = t;
        s.offset[currentScopeDepth] = currentStackOffset; 
        s.depth = currentScopeDepth;
        symbolTable[name] = s;
    }
    currentStackOffset++; 
}

void exitScope() {
    // cerr << "DEBUG: exitScope() from depth " << currentScopeDepth << endl;
    // Remove symbols defined in the current scope
    vector<string> toRemove;
    for (auto& entry : symbolTable) {
        if (entry.second.depth == currentScopeDepth) {
            // cerr << "DEBUG: Removing " << entry.first << " from depth " << currentScopeDepth << endl;
            entry.second.type.erase(currentScopeDepth);
            entry.second.offset.erase(currentScopeDepth);
            
            // Find the previous depth
            int maxDepth = -1;
            for (auto const& mapEntry : entry.second.type) {
                int depth = mapEntry.first;
                if (depth > maxDepth) maxDepth = depth;
            }
            
            if (maxDepth != -1) {
                entry.second.depth = maxDepth;
            } else {
                toRemove.push_back(entry.first);
            }
        }
    }
    for (const string& name : toRemove) {
        symbolTable.erase(name);
    }
    currentScopeDepth--;
}

Type getSymbolType(string name) {
    // cerr << "DEBUG: getSymbolType(" << name << ") at depth " << currentScopeDepth << endl;
    if (symbolTable.find(name) == symbolTable.end()) {
        cerr << "Semantic error: Undeclared variable in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    return symbolTable[name].type[symbolTable[name].depth];
}

int getSymbolOffset(string name) {
    if (symbolTable.find(name) == symbolTable.end()) {
        exit(SEMANTIC_ERROR);
    }
    return symbolTable[name].offset[symbolTable[name].depth];
}

#define YYSTYPE yystype

%}

%token ID INTEGERNUM REALNUM STR
%token INT FLOAT VOID
%token WRITE READ RETURN
%token IF WHILE DO
%token ASSIGN
%token RELOP ADDOP MULOP
%token AND OR NOT
%token LPAREN RPAREN LCURLY RCURLY COMMA SEMICOLON COLON
%token THEN ELSE

%right ASSIGN
%left OR
%left AND
%left RELOP
%left ADDOP
%left MULOP
%right NOT
%left LPAREN RPAREN
%nonassoc LOWER_THAN_ELSE
%nonassoc ELSE

%%

PROGRAM : { buffer = new Buffer(); } FDEFS {
    // End of program parsing. Header generation is handled in main().
}
;

FDEFS   : FDEFS FUNC_DEF_API FUNC_BLK {
            // Implicit return for void functions at the end of the function body
            if (currentFuncType == void_t) {
                buffer->emit("RETRN");
            }
        }
        
        | FDEFS FUNC_DEC_API
        | /* epsilon */
        ;

FUNC_DEC_API : TYPE ID LPAREN FUNC_ARGLIST RPAREN SEMICOLON {
    string name = $2.name;
    if (functionTable.count(name) && functionTable[name].isDefined) {
        Function& f = functionTable[name];
        bool mismatch = false;
        if (f.returnType != $1.type) mismatch = true;
        if (f.paramTypes.size() != $4.paramTypes.size()) mismatch = true;
        else {
            for(size_t i=0; i<f.paramTypes.size(); i++) {
                if (f.paramTypes[i] != $4.paramTypes[i]) mismatch = true;
            }
        }
        
        if (mismatch) {
            cerr << "Semantic error: Function '" << name << "' redeclared with different signature in line number " << line_number << endl;
            exit(SEMANTIC_ERROR);
        }
    } else {
        Function f;
        f.isDefined = false;
        f.returnType = $1.type;
        f.paramTypes = $4.paramTypes;
        f.paramIds = $4.paramIds;
        functionTable[name] = f;
    }
}
| TYPE ID LPAREN RPAREN SEMICOLON {
    string name = $2.name;
    if (functionTable.count(name) && functionTable[name].isDefined) {
        Function& f = functionTable[name];
        if (f.returnType != $1.type || !f.paramTypes.empty()) {
             cerr << "Semantic error: Function '" << name << "' redeclared with different signature in line number " << line_number << endl;
             exit(SEMANTIC_ERROR);
        }
    } else {
        Function f;
        f.isDefined = false;
        f.returnType = $1.type;
        functionTable[name] = f;
    }
}
;

FUNC_DEF_API : TYPE ID LPAREN FUNC_ARGLIST RPAREN {
    string name = $2.name;
    if (functionTable.count(name) && functionTable[name].isDefined) {
        cerr << "Semantic error: Function redefined in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    
    functionTable[name].isDefined = true;
    functionTable[name].startLineImplementation = buffer->nextQuad();
    functionTable[name].returnType = $1.type;
    functionTable[name].paramTypes = $4.paramTypes;
    functionTable[name].paramIds = $4.paramIds; 
    
    currentFuncName = name;
    currentFuncType = $1.type;
    currentStackOffset = 0; 
    
    currentScopeDepth++; 
    // Emit placeholder for stack frame allocation
    stackFrameSizePlaceholderLine = buffer->nextQuad();
    buffer->emit("# STACK_FRAME_PLACEHOLDER");
    // Parameters get negative offsets from I1: -8, -12, -16, etc.
    // (I1-4 is reserved for return value)
    int paramOffset = -8;
    for (size_t i=0; i<$4.paramIds.size(); ++i) {
        string pname = $4.paramIds[i];
        Type ptype = $4.paramTypes[i];
        // Add to symbol table with negative offset
        if (symbolTable.find(pname) != symbolTable.end() && symbolTable[pname].depth == currentScopeDepth) {
            cerr << "Semantic error: Duplicate parameter name in line number " << line_number << endl;
            exit(SEMANTIC_ERROR);
        }
        Symbol s;
        s.type[currentScopeDepth] = ptype;
        s.offset[currentScopeDepth] = paramOffset;
        s.depth = currentScopeDepth;
        symbolTable[pname] = s;
        paramOffset -= 4;
    }
}
| TYPE ID LPAREN RPAREN {
    string name = $2.name;
    if (functionTable.count(name) && functionTable[name].isDefined) {
        cerr << "Semantic error: Function redefined in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    functionTable[name].isDefined = true;
    functionTable[name].startLineImplementation = buffer->nextQuad();
    functionTable[name].returnType = $1.type;
    currentFuncName = name;
    currentFuncType = $1.type;
    currentStackOffset = 0;
    currentScopeDepth++;
    
    // Emit placeholder for stack frame allocation
    stackFrameSizePlaceholderLine = buffer->nextQuad();
    buffer->emit("# STACK_FRAME_PLACEHOLDER");
}
;

FUNC_ARGLIST : FUNC_ARGLIST COMMA DCL {
    $$.paramTypes = $1.paramTypes;
    for(size_t i = 0; i < $3.paramTypes.size(); i++) {
        $$.paramTypes.push_back($3.paramTypes[i]);
    }
    $$.paramIds = $1.paramIds;
    for(size_t i = 0; i < $3.paramIds.size(); i++) {
        $$.paramIds.push_back($3.paramIds[i]);
    }
}
| DCL {
    $$.paramTypes = $1.paramTypes;
    $$.paramIds = $1.paramIds;
}
;

DCL : ID COLON TYPE {
    $$.name = $1.name;
    $$.type = $3.type;
    $$.paramIds.clear();
    $$.paramIds.push_back($1.name);
    $$.paramTypes.clear();
    $$.paramTypes.push_back($3.type);
}
| ID COMMA DCL {
    // Grouped declaration: a,b:int means a gets same type as b
    $$.name = $1.name;
    $$.type = $3.type;  // Use type from the rest of the declaration
    $$.paramIds.clear();
    $$.paramIds.push_back($1.name);
    for(size_t i = 0; i < $3.paramIds.size(); i++) {
        $$.paramIds.push_back($3.paramIds[i]);
    }
    $$.paramTypes.clear();
    $$.paramTypes.push_back($3.type);
    for(size_t i = 0; i < $3.paramTypes.size(); i++) {
        $$.paramTypes.push_back($3.paramTypes[i]);
    }
}
;

TYPE : INT   { $$.type = int_; }
     | FLOAT { $$.type = float_; }
     | VOID  { $$.type = void_t; }
     ;

FUNC_BLK : LCURLY STLIST RCURLY {
    // Backpatch any remaining nextList jumps to here (end of function)
    buffer->backpatch($2.nextList, buffer->nextQuad());
    // Replace placeholder with actual stack frame allocation
    int localBytes = currentStackOffset * 4;
    // Always emit ADD2I even if 0 (harmless but valid instruction)
    buffer->replace(stackFrameSizePlaceholderLine, "ADD2I I2 I2 " + intToString(localBytes));
    exitScope();
}
;

BLK : LCURLY { currentScopeDepth++; } STLIST RCURLY {
    exitScope();
    // NOTE: We do NOT emit RETRN here anymore. It's handled in FDEFS.
}
;

STLIST : STLIST MARKER STMT {
    buffer->backpatch($1.nextList, $2.quad);
    $$.nextList = $3.nextList;
}
| /* epsilon */ { $$.nextList = vector<int>(); }
;

MARKER : { $$.quad = buffer->nextQuad(); } ;

STMT : DCL SEMICOLON { 
       // Handle grouped declarations like a,b:int
       for(size_t i = 0; i < $1.paramIds.size(); i++) {
           addSymbol($1.paramIds[i], $1.paramTypes[i]); 
       }
       $$.nextList = vector<int>();
     }
     | ASSN { $$.nextList = vector<int>(); }
     | RETURN_STMT { $$.nextList = vector<int>(); }
     | CALL SEMICOLON { $$.nextList = vector<int>(); }
     | WRITE_STMT { $$.nextList = vector<int>(); }
     | READ_STMT { $$.nextList = vector<int>(); }
     | BLK { $$.nextList = $1.nextList; }
     | IF BEXP THEN MARKER STMT ELSE N MARKER STMT {
         buffer->backpatch($2.trueList, $4.quad);
         buffer->backpatch($2.falseList, $8.quad);
         vector<int> temp = merge($5.nextList, $7.nextList);
         $$.nextList = merge(temp, $9.nextList);
     }
     | IF BEXP THEN MARKER STMT %prec LOWER_THAN_ELSE {
         buffer->backpatch($2.trueList, $4.quad);
         $$.nextList = merge($2.falseList, $5.nextList);
     }
     | WHILE MARKER BEXP DO MARKER STMT {
         buffer->backpatch($3.trueList, $5.quad);
         buffer->backpatch($6.nextList, $2.quad);
         // Important: No '0' placeholder here.
         buffer->emit("UJUMP " + intToString($2.quad));
         $$.nextList = $3.falseList;
     }
     ;

ASSN : ID ASSIGN EXP SEMICOLON {
    Type varType = getSymbolType($1.name);
    int offset = getSymbolOffset($1.name);
    
    if (varType != $3.type) {
        cerr << "Semantic error: Type mismatch in assignment in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    
    if (varType == int_) {
        if (offset < 0) {
            // Parameter: use I1 with negative offset
            buffer->emit("STORI I" + intToString($3.RegNum) + " I1 " + intToString(offset));
        } else {
            // Local variable: use I1 with positive offset
            buffer->emit("STORI I" + intToString($3.RegNum) + " I1 " + intToString(offset * 4));
        }
    } else {
        // STORF needs float base register
        int floatBase = nextReg(float_);
        if (offset < 0) {
            // Parameter: use I1 (offset already in bytes)
            buffer->emit("CITOF F" + intToString(floatBase) + " I1");
            buffer->emit("STORF F" + intToString($3.RegNum) + " F" + intToString(floatBase) + " " + intToString(offset));
        } else {
            // Local variable: use I1 with positive offset
            buffer->emit("CITOF F" + intToString(floatBase) + " I1");
            buffer->emit("STORF F" + intToString($3.RegNum) + " F" + intToString(floatBase) + " " + intToString(offset * 4));
        }
    }
}
;

EXP : EXP ADDOP EXP {
    if ($1.type != $3.type) {
        cerr << "Semantic error: Type mismatch in arithmetic op in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    $$.type = $1.type;
    $$.RegNum = nextReg($$.type);
    string op = $2.name;
    string cmd = ($$.type == int_) ? (op == "+" ? "ADD2I" : "SUBTI") : (op == "+" ? "ADD2F" : "SUBTF");
    if ($$.type == int_) {
        buffer->emit(cmd + " I" + intToString($$.RegNum) + " I" + intToString($1.RegNum) + " I" + intToString($3.RegNum));
    } else {
        buffer->emit(cmd + " F" + intToString($$.RegNum) + " F" + intToString($1.RegNum) + " F" + intToString($3.RegNum));
    }
}
| EXP MULOP EXP {
    if ($1.type != $3.type) { 
        cerr << "Semantic error: Type mismatch in arithmetic op in line number " << line_number << endl;
        exit(SEMANTIC_ERROR); 
    }
    $$.type = $1.type;
    $$.RegNum = nextReg($$.type);
    string op = $2.name;
    string cmd = ($$.type == int_) ? (op == "*" ? "MULTI" : "DIVDI") : (op == "*" ? "MULTF" : "DIVDF");
    if ($$.type == int_) {
        buffer->emit(cmd + " I" + intToString($$.RegNum) + " I" + intToString($1.RegNum) + " I" + intToString($3.RegNum));
    } else {
        buffer->emit(cmd + " F" + intToString($$.RegNum) + " F" + intToString($1.RegNum) + " F" + intToString($3.RegNum));
    }
}
| LPAREN EXP RPAREN { 
    $$ = $2; 
}
| LPAREN TYPE RPAREN EXP {
    if ($2.type == $4.type) { $$ = $4; } 
    else if ($2.type == float_ && $4.type == int_) {
        $$.type = float_;
        $$.RegNum = nextReg(float_);
        buffer->emit("CITOF F" + intToString($$.RegNum) + " I" + intToString($4.RegNum));
    } else if ($2.type == int_ && $4.type == float_) {
        $$.type = int_;
        $$.RegNum = nextReg(int_);
        buffer->emit("CFTOI I" + intToString($$.RegNum) + " F" + intToString($4.RegNum));
    } else {
        cerr << "Semantic error: Invalid cast in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
}
| ID {
    $$.type = getSymbolType($1.name);
    $$.RegNum = nextReg($$.type);
    int offset = getSymbolOffset($1.name);
    if ($$.type == int_) {
        if (offset < 0) {
            // Parameter: use I1 with negative offset
            buffer->emit("LOADI I" + intToString($$.RegNum) + " I1 " + intToString(offset));
        } else {
            // Local variable: use I1 with positive offset
            // We reserved space on stack (ADD2I I2 I2 ...), so locals are at I1 + offset*4
            buffer->emit("LOADI I" + intToString($$.RegNum) + " I1 " + intToString(offset * 4));
        }
    } else {
        // LOADF needs float base register
        int floatBase = nextReg(float_);
        if (offset < 0) {
            // Parameter: use I1 with negative offset (already in bytes)
            buffer->emit("CITOF F" + intToString(floatBase) + " I1");
            buffer->emit("LOADF F" + intToString($$.RegNum) + " F" + intToString(floatBase) + " " + intToString(offset));
        } else {
            // Local variable: use I1 with positive offset
            buffer->emit("CITOF F" + intToString(floatBase) + " I1");
            buffer->emit("LOADF F" + intToString($$.RegNum) + " F" + intToString(floatBase) + " " + intToString(offset * 4));
        }
    }
}
| INTEGERNUM {
    $$.type = int_;
    $$.RegNum = nextReg(int_);
    buffer->emit("COPYI I" + intToString($$.RegNum) + " " + $1.name);
}
| REALNUM {
    $$.type = float_;
    $$.RegNum = nextReg(float_);
    buffer->emit("COPYF F" + intToString($$.RegNum) + " " + $1.name);
}
| CALL { $$ = $1; }
;

BEXP : BEXP OR MARKER BEXP {
    buffer->backpatch($1.falseList, $3.quad);
    $$.trueList = merge($1.trueList, $4.trueList);
    $$.falseList = $4.falseList;
}
| BEXP AND MARKER BEXP {
    buffer->backpatch($1.trueList, $3.quad);
    $$.trueList = $4.trueList;
    $$.falseList = merge($1.falseList, $4.falseList);
}
| NOT BEXP {
    $$.trueList = $2.falseList;
    $$.falseList = $2.trueList;
}
| LPAREN BEXP RPAREN { $$ = $2; }
| EXP RELOP EXP {
    if ($1.type != $3.type) {
        cerr << "Semantic error: Type mismatch in relation in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    
    int tempReg = nextReg(int_);
    string op = $2.name;
    string cmd = "";
    
    if ($1.type == int_) {
        if (op == "==") cmd = "SEQUI";
        else if (op == "<>") cmd = "SNEQI";
        else if (op == ">")  cmd = "SGRTI";
        else if (op == "<") {
            // a < b is equivalent to b > a
            cmd = "SGRTI";
            buffer->emit(cmd + " I" + intToString(tempReg) + " I" + intToString($3.RegNum) + " I" + intToString($1.RegNum));
            cmd = ""; // Already emitted
        }
        else if (op == "<=") {
            // a <= b is equivalent to NOT (a > b)
            int tempReg2 = nextReg(int_);
            int zeroReg = nextReg(int_);
            buffer->emit("COPYI I" + intToString(zeroReg) + " 0");
            buffer->emit("SGRTI I" + intToString(tempReg2) + " I" + intToString($1.RegNum) + " I" + intToString($3.RegNum));
            buffer->emit("SEQUI I" + intToString(tempReg) + " I" + intToString(tempReg2) + " I" + intToString(zeroReg)); // result = (temp == 0)
            cmd = ""; // Already emitted
        }
        else if (op == ">=") {
            // a >= b is equivalent to NOT (a < b) = NOT (b > a)
            int tempReg2 = nextReg(int_);
            int zeroReg = nextReg(int_);
            buffer->emit("COPYI I" + intToString(zeroReg) + " 0");
            buffer->emit("SGRTI I" + intToString(tempReg2) + " I" + intToString($3.RegNum) + " I" + intToString($1.RegNum));
            buffer->emit("SEQUI I" + intToString(tempReg) + " I" + intToString(tempReg2) + " I" + intToString(zeroReg)); // result = (temp == 0)
            cmd = ""; // Already emitted
        }
        if (cmd != "") buffer->emit(cmd + " I" + intToString(tempReg) + " I" + intToString($1.RegNum) + " I" + intToString($3.RegNum));
    } else {
        // Float comparison: result goes to F register first, then convert to I
        int floatResReg = nextReg(float_);
        if (op == "==") cmd = "SEQUF";
        else if (op == "<>") cmd = "SNEQF";
        else if (op == ">")  cmd = "SGRTF";
        else if (op == "<") {
            // a < b is equivalent to b > a
            cmd = "SGRTF";
            buffer->emit(cmd + " F" + intToString(floatResReg) + " F" + intToString($3.RegNum) + " F" + intToString($1.RegNum));
            buffer->emit("CFTOI I" + intToString(tempReg) + " F" + intToString(floatResReg));
            cmd = ""; // Already emitted
        }
        else if (op == "<=") {
            // a <= b is equivalent to NOT (a > b)
            buffer->emit("SGRTF F" + intToString(floatResReg) + " F" + intToString($1.RegNum) + " F" + intToString($3.RegNum));
            int tempReg2 = nextReg(int_);
            int zeroReg = nextReg(int_);
            buffer->emit("COPYI I" + intToString(zeroReg) + " 0");
            buffer->emit("CFTOI I" + intToString(tempReg2) + " F" + intToString(floatResReg));
            buffer->emit("SEQUI I" + intToString(tempReg) + " I" + intToString(tempReg2) + " I" + intToString(zeroReg)); // result = (temp == 0)
            cmd = ""; // Already emitted
        }
        else if (op == ">=") {
            // a >= b is equivalent to NOT (b > a)
            buffer->emit("SGRTF F" + intToString(floatResReg) + " F" + intToString($3.RegNum) + " F" + intToString($1.RegNum));
            int tempReg2 = nextReg(int_);
            int zeroReg = nextReg(int_);
            buffer->emit("COPYI I" + intToString(zeroReg) + " 0");
            buffer->emit("CFTOI I" + intToString(tempReg2) + " F" + intToString(floatResReg));
            buffer->emit("SEQUI I" + intToString(tempReg) + " I" + intToString(tempReg2) + " I" + intToString(zeroReg)); // result = (temp == 0)
            cmd = ""; // Already emitted
        }
        if (cmd != "") {
            buffer->emit(cmd + " F" + intToString(floatResReg) + " F" + intToString($1.RegNum) + " F" + intToString($3.RegNum));
            buffer->emit("CFTOI I" + intToString(tempReg) + " F" + intToString(floatResReg));
        }
    }
    
    $$.trueList = vector<int>();
    $$.trueList.push_back(buffer->nextQuad());
    // Important: No '0' placeholder here. Space at the end.
    buffer->emit("BNEQZ I" + intToString(tempReg) + " "); 
    
    $$.falseList = vector<int>();
    $$.falseList.push_back(buffer->nextQuad());
    // Important: No '0' placeholder here. Space at the end.
    buffer->emit("UJUMP "); 
}
;

CALL : ID LPAREN CALL_ARGS RPAREN {
    string name = $1.name;
    if (functionTable.find(name) == functionTable.end()) {
        cerr << "Semantic error: Function '" << name << "' undefined in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    
    Function& func = functionTable[name];
    vector<Type> expectedTypes = func.paramTypes;
    vector<string> expectedNames = func.paramIds;
    
    if ($3.paramTypes.size() != expectedTypes.size()) {
         cerr << "Semantic error: Wrong number of arguments in line number " << line_number << endl;
         exit(SEMANTIC_ERROR);
    }

    vector<bool> assigned(expectedTypes.size(), false);
    
    for (size_t i = 0; i < $3.paramTypes.size(); ++i) {
        if ($3.paramIds[i] == "") { // Positional arg
            for(size_t k=0; k<i; ++k) {
                if ($3.paramIds[k] != "") {
                    cerr << "Semantic error: Positional argument after named argument in line number " << line_number << endl;
                    exit(SEMANTIC_ERROR);
                }
            }
            if (assigned[i]) {
                 cerr << "Semantic error: Parameter assigned twice in line number " << line_number << endl;
                 exit(SEMANTIC_ERROR);
            }
            if ($3.paramTypes[i] != expectedTypes[i]) {
                 cerr << "Semantic error: Type mismatch for argument " << (i+1) << " in line number " << line_number << endl;
                 exit(SEMANTIC_ERROR);
            }
            assigned[i] = true;
        } 
        else { // Named arg
            string label = $3.paramIds[i];
            bool found = false;
            for(size_t j=0; j<expectedNames.size(); ++j) {
                if (expectedNames[j] == label) {
                    if (assigned[j]) {
                        cerr << "Semantic error: Parameter passed twice in line number " << line_number << endl;
                        exit(SEMANTIC_ERROR);
                    }
                    if ($3.paramTypes[i] != expectedTypes[j]) {
                        cerr << "Semantic error: Type mismatch for parameter '" << label << "' in line number " << line_number << endl;
                        exit(SEMANTIC_ERROR);
                    }
                    assigned[j] = true;
                    found = true;
                    break;
                }
            }
            if (!found) {
                cerr << "Semantic error: Unknown named parameter in line number " << line_number << endl;
                exit(SEMANTIC_ERROR);
            }
        }
    }

    for(bool b : assigned) {
        if(!b) {
            cerr << "Semantic error: Not all parameters assigned in call to '" << name << "' in line number " << line_number << endl;
            exit(SEMANTIC_ERROR);
        }
    }

    // Build reordered argument arrays to match parameter order
    vector<Type> reorderedTypes(expectedTypes.size());
    vector<int> reorderedRegs(expectedTypes.size());
    
    for (size_t i = 0; i < $3.paramTypes.size(); ++i) {
        if ($3.paramIds[i] == "") { // Positional arg
            reorderedTypes[i] = $3.paramTypes[i];
            reorderedRegs[i] = $3.paramRegs[i];
        } else { // Named arg - find its position
            string label = $3.paramIds[i];
            for(size_t j=0; j<expectedNames.size(); ++j) {
                if (expectedNames[j] == label) {
                    reorderedTypes[j] = $3.paramTypes[i];
                    reorderedRegs[j] = $3.paramRegs[i];
                    break;
                }
            }
        }
    }

    // ============ CALLING CONVENTION ============
    // 1. Save registers to stack at I2
    int numIntToSave = regIdxInt;   // Save I0 to I(regIdxInt-1)
    int numFloatToSave = regIdxFloat; // Save F0 to F(regIdxFloat-1)
    int intSaveBytes = numIntToSave * 4;
    int floatSaveBytes = numFloatToSave * 4;
    int totalSaveBytes = intSaveBytes + floatSaveBytes;
    // Round up to multiple of 4
    if (totalSaveBytes % 4 != 0) totalSaveBytes += (4 - totalSaveBytes % 4);
    
    // Need float base for STORF
    buffer->emit("CITOF F" + intToString(regIdxFloat) + " I2");
    int floatBaseForSave = regIdxFloat;
    
    // Save int registers
    for (int i = 0; i < numIntToSave; i++) {
        buffer->emit("STORI I" + intToString(i) + " I2 " + intToString(i * 4));
    }
    // Save float registers  
    for (int i = 0; i < numFloatToSave; i++) {
        buffer->emit("STORF F" + intToString(i) + " F" + intToString(floatBaseForSave) + " " + intToString(intSaveBytes + i * 4));
    }
    
    // 2. Advance stack pointer
    // Must leave room for arguments (-8, -12...) and retval (-4) BELOW the new I2
    int argsBytes = reorderedTypes.size() * 4;
    int totalStackAdvance = totalSaveBytes + argsBytes + 4;
    // Keep 4-byte alignment (should already be aligned, but safe to check)
    if (totalStackAdvance % 4 != 0) totalStackAdvance += (4 - totalStackAdvance % 4);
    
    buffer->emit("ADD2I I2 I2 " + intToString(totalStackAdvance));
    
    // 3. Set frame pointer I1 = I2
    buffer->emit("COPYI I1 I2");
    buffer->emit("CITOF F1 I1");
    
    // 4. Store arguments at negative offsets from I1
    // Arguments go at I1-8, I1-12, I1-16, etc. (I1-4 is for return value)
    int argOffset = -8;
    for (size_t i = 0; i < reorderedTypes.size(); i++) {
        Type argType = reorderedTypes[i];
        int argReg = reorderedRegs[i];
        
        if (argType == int_) {
            buffer->emit("STORI I" + intToString(argReg) + " I1 " + intToString(argOffset));
        } else {
            buffer->emit("STORF F" + intToString(argReg) + " F1 " + intToString(argOffset));
        }
        argOffset -= 4;
    }
    
    // 5. JLINK to function
    func.callingLines.push_back(buffer->nextQuad());
    buffer->emit("JLINK 0"); 
    
    // 6. After return: I2 = I1
    buffer->emit("COPYI I2 I1");
    
    // 7. Load return value from I1-4
    int returnValueReg = -1;
    if (func.returnType == int_) {
        $$.type = int_;
        $$.RegNum = nextReg(int_);
        returnValueReg = $$.RegNum;
        buffer->emit("LOADI I" + intToString($$.RegNum) + " I1 -4");
    } else if (func.returnType == float_) {
        $$.type = float_;
        $$.RegNum = nextReg(float_);
        returnValueReg = $$.RegNum;
        int floatBase = nextReg(float_);
        buffer->emit("CITOF F" + intToString(floatBase) + " I1");
        buffer->emit("LOADF F" + intToString($$.RegNum) + " F" + intToString(floatBase) + " -4");
    }
    
    // 8. Restore I2 (subtract save area)
    buffer->emit("SUBTI I2 I2 " + intToString(totalStackAdvance));
    int floatBaseForRestore = nextReg(float_);
    buffer->emit("CITOF F" + intToString(floatBaseForRestore) + " I2");
    
    // 9. Restore registers (skip I2, and skip return value reg)
    for (int i = 0; i < numIntToSave; i++) {
        if (i == 2) continue;  // Don't restore I2 - already computed
        buffer->emit("LOADI I" + intToString(i) + " I2 " + intToString(i * 4));
    }
    for (int i = 0; i < numFloatToSave; i++) {
        buffer->emit("LOADF F" + intToString(i) + " F" + intToString(floatBaseForRestore) + " " + intToString(intSaveBytes + i * 4));
    }
}
;

CALL_ARGS : POS_ARGLIST { $$ = $1; }
          | NAMED_ARGLIST { $$ = $1; }
          | POS_ARGLIST COMMA NAMED_ARGLIST {
              $$.paramTypes = merge($1.paramTypes, $3.paramTypes);
              $$.paramIds = merge($1.paramIds, $3.paramIds);
              $$.paramRegs = merge($1.paramRegs, $3.paramRegs);
          }
          | /* epsilon */ { }
          ;

POS_ARGLIST : EXP {
    $$.paramTypes.push_back($1.type);
    $$.paramIds.push_back(""); 
    $$.paramRegs.push_back($1.RegNum);
}
| POS_ARGLIST COMMA EXP {
    $$.paramTypes = $1.paramTypes;
    $$.paramTypes.push_back($3.type);
    $$.paramIds = $1.paramIds;
    $$.paramIds.push_back("");
    $$.paramRegs = $1.paramRegs;
    $$.paramRegs.push_back($3.RegNum);
}
;

NAMED_ARGLIST : NAMED_ARG { $$ = $1; }
              | NAMED_ARGLIST COMMA NAMED_ARG {
                  $$.paramTypes = merge($1.paramTypes, $3.paramTypes);
                  $$.paramIds = merge($1.paramIds, $3.paramIds);
                  $$.paramRegs = merge($1.paramRegs, $3.paramRegs);
              }
              ;

NAMED_ARG : ID COLON EXP {
    $$.paramTypes.push_back($3.type);
    $$.paramIds.push_back($1.name); 
    $$.paramRegs.push_back($3.RegNum);
}
;

RETURN_STMT : RETURN EXP SEMICOLON {
    if (currentFuncType == void_t) {
        cerr << "Semantic error: Cannot return value from void function in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    if (currentFuncType != $2.type) {
        cerr << "Semantic error: Return type mismatch in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    
    // Store return value at I1-4 (not I0, which holds return address)
    if ($2.type == int_) {
        buffer->emit("STORI I" + intToString($2.RegNum) + " I1 -4");
    } else {
        // For float, need float base
        buffer->emit("CITOF F1 I1");
        buffer->emit("STORF F" + intToString($2.RegNum) + " F1 -4");
    }
    
    buffer->emit("RETRN");
}
| RETURN SEMICOLON {
    if (currentFuncType != void_t) {
        cerr << "Semantic error: Must return value from non-void function in line number " << line_number << endl;
        exit(SEMANTIC_ERROR);
    }
    buffer->emit("RETRN");
}
;

WRITE_STMT : WRITE LPAREN EXP RPAREN SEMICOLON {
    if ($3.type == int_) buffer->emit("PRNTI I" + intToString($3.RegNum));
    else buffer->emit("PRNTF F" + intToString($3.RegNum));
}
| WRITE LPAREN STR RPAREN SEMICOLON {
    string s = $3.name;
    for (size_t i = 0; i < s.length(); ++i) {
        if (s[i] == '\\' && i + 1 < s.length()) {
            char nextC = s[i+1];
            if (nextC == 'n') { buffer->emit("PRNTC 10"); i++; }
            else if (nextC == 't') { buffer->emit("PRNTC 9"); i++; }
            else if (nextC == '\"') { buffer->emit("PRNTC 34"); i++; }
            else if (nextC == '\\') { buffer->emit("PRNTC 92"); i++; }
            else { buffer->emit("PRNTC " + intToString((int)s[i])); }
        } else {
            buffer->emit("PRNTC " + intToString((int)s[i]));
        }
    }
}
;

READ_STMT : READ LPAREN LVAL RPAREN SEMICOLON {
    int offset = getSymbolOffset($3.name);
    Type t = getSymbolType($3.name);
    int r = nextReg(t);
    if (t == int_) {
        buffer->emit("READI I" + intToString(r));
        if (offset < 0) {
            // Parameter: use I1
            buffer->emit("STORI I" + intToString(r) + " I1 " + intToString(offset));
        } else {
            // Local variable: use I1 with positive offset
            buffer->emit("STORI I" + intToString(r) + " I1 " + intToString(offset * 4));
        }
    } else {
        buffer->emit("READF F" + intToString(r));
        // STORF needs float base register
        int floatBase = nextReg(float_);
        if (offset < 0) {
            // Parameter: use I1 (offset already in bytes)
            buffer->emit("CITOF F" + intToString(floatBase) + " I1");
            buffer->emit("STORF F" + intToString(r) + " F" + intToString(floatBase) + " " + intToString(offset));
        } else {
            // Local variable: use I1 with positive offset
            buffer->emit("CITOF F" + intToString(floatBase) + " I1");
            buffer->emit("STORF F" + intToString(r) + " F" + intToString(floatBase) + " " + intToString(offset * 4));
        }
    }
}
;

LVAL : ID { 
    $$.name = $1.name; 
} ;

N : { 
    $$.nextList = vector<int>(); 
    $$.nextList.push_back(buffer->nextQuad());
    // Important: No '0' placeholder here.
    buffer->emit("UJUMP "); 
} 
;

%%

void yyerror(const char* s) {
    cerr << "Syntax error: '" << yytext << "' in line number " << line_number << endl;
    exit(SYNTAX_ERROR);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        cerr << "Operational error: No input file." << endl;
        exit(OPERATIONAL_ERROR);
    }
    
    string inputFileName = argv[1];
    
    if (inputFileName.substr(inputFileName.find_last_of(".") + 1) != "cmm") {
        cerr << "Operational error: Input file must have .cmm extension" << endl;
        exit(OPERATIONAL_ERROR);
    }

    yyin = fopen(argv[1], "r");
    if (!yyin) {
        cerr << "Operational error: Cannot open file." << endl;
        exit(OPERATIONAL_ERROR);
    }
    
    yyparse();
    
    // Link local calls
    for(auto const& entry : functionTable) {
        const Function& func = entry.second;
        if (func.isDefined) {
            for(int line : func.callingLines) {
                // Compile-time linking for local functions
                buffer->replace(line, "JLINK " + intToString(func.startLineImplementation));
            }
        }
    }

    string outputFileName = inputFileName.substr(0, inputFileName.find_last_of(".")) + ".rsk";
    ofstream outFile(outputFileName);
    if (!outFile.is_open()) {
        cerr << "Operational error: Cannot create output file." << endl;
        exit(OPERATIONAL_ERROR);
    }

    outFile << "<header>" << endl;
    
    vector<string> unimplemented;
    vector<string> implemented;

    // Standard Iterator Loop (C++11 compatible)
    for(auto const& entry : functionTable) {
        string name = entry.first;
        const Function& func = entry.second;

        if (func.isDefined) {
            implemented.push_back(name + "," + intToString(func.startLineImplementation));
        } else {
            if (!func.callingLines.empty()) {
                string s = name;
                for(int line : func.callingLines) {
                    s += "," + intToString(line);
                }
                unimplemented.push_back(s);
            }
        }
    }

    outFile << "<unimplemented> ";
    for(size_t i = 0; i < unimplemented.size(); ++i) outFile << unimplemented[i] << (i < unimplemented.size()-1 ? " " : "");
    outFile << endl;

    outFile << "<implemented> ";
    for(size_t i = 0; i < implemented.size(); ++i) outFile << implemented[i] << (i < implemented.size()-1 ? " " : "");
    outFile << endl;

    outFile << "</header>" << endl;
    
    outFile << buffer->printBuffer();
    
    outFile.close();
    return 0;
}