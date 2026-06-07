CC = g++
CFLAGS = -g -Wall -std=c++11
YACC = bison
LEX = flex

EXEC = rx-cc
BISON_SRC = part3.y
LEX_SRC = part1.lex

all: $(EXEC)

$(EXEC): part3.tab.cpp lex.yy.c part3_helpers.cpp
	$(CC) $(CFLAGS) -o $(EXEC) part3.tab.cpp lex.yy.c part3_helpers.cpp

part3.tab.cpp part3.tab.hpp: $(BISON_SRC)
	$(YACC) -d -o part3.tab.cpp $(BISON_SRC)

lex.yy.c: $(LEX_SRC) part3.tab.hpp
	$(LEX) -o lex.yy.c $(LEX_SRC)

clean:
	rm -f $(EXEC) part3.tab.cpp part3.tab.hpp lex.yy.c