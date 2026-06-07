#include "part3_helpers.hpp"


Buffer::Buffer(){
	data.clear();
}

string Buffer::printBuffer() {
	string out = "";
	for (int i=0; i<data.size(); ++i) {
		out += data[i] + "\n";
	}
	return out;
}
void Buffer::emit(const string& str) {
	data.push_back(str);
}

void Buffer::frontEmit(const string& str) {
	data.insert(data.begin(), str);
}

int Buffer::nextQuad() {
	return data.size() + 1;
}


void Buffer::backpatch(vector<int> lst, int line) {
	for (unsigned i=0; i < lst.size(); ++i) {
		data[lst[i] - 1] += intToString(line) +" ";
	}
}

// Added method to replace instruction at specific line (1-based)
void Buffer::replace(int line, const string& cmd) {
    if(line > 0 && line <= (int)data.size()) {
        data[line - 1] = cmd;
    }
}