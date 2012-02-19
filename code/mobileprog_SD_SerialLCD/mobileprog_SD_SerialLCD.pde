/*
 Harry Johnson, 11/6/10
 NOTE: uses some hacks, and doesn't implement a full STK500 protocol.
 Also: Currently doesn't compare what the target chip actually ends up having to what it thought it programmed.
 Doesn't store what used to be in the chip, so if something goes wrong whatever is on the target before will be lost.
 Further note: Seems to actually work!!!! 
 This is the version with a software serial line, instead of a built in LCD
 */
#include <SdFat.h>
#include <SdFatUtil.h>
#include <NewSoftSerial.h>

#define NIB2BYTE(h, l) ((h<<4) | l) // 2 nibbles to a byte. 
#define TWOSCOMP(x) (((x ^ 0xFF)+1) & 0xFF) //2's compliment of a byte.
#define HIBYTE(x) ((x>>8) & 0xFF)
#define LOBYTE(x) (x & 0xFF)
#define NUMDATABYTES 16 //number of data bytes, maximum, per line.

//pin numbers for software serial library
#define LCDRX 18
#define LCDTX 19

//LCD functions
#define LCD_CLS "?f"
#define LOWERLEFT "?x00?y1"

//pin numbers for next and select pins.
#define NEXT 8
#define SELECT 9
#define TARG_RESET 2

//STK constants
#define CRC_EOP             0x20
#define STK_OK              0x10
#define STK_INSYNC          0x14
#define STK_GET_SYNC        0x30
#define STK_LOAD_ADDRESS    0x55
#define STK_PROG_PAGE       0x64
#define STK_READ_PAGE       0x74
#define STK_READ_SIGN       0x75
//other constants
#define TIMEOUT 1000 // 1 second comm timeout. can probably be brought down. 
#define verify 0 //0 for file verify off, 1 for on.
//file verify on: Low speed downloading, on the go error checking. This doesn't mean a ton since I don't store the original program for re-upload. Seems good to have, though.
//file verify off: Higher speed downloading, especially with big files. Recommended option. 
#define progressbar 1 // 0/1 for progress bar off/on. For large programs, the initial size calculation can take some time. Disable for even faster downloading.


//data for current line of file.
int pagesize = 0;
word pageAddress; //word address
byte recordType; //EOF = 1
byte numPageBytes; //number of bytes so far on this page.
long int numTotalBytes = 0;
byte data[256]; //128 bytes, 64 words.
byte tmp[128];
//SD card variables
Sd2Card card;
SdVolume volume;
SdFile root;
SdFile file;

NewSoftSerial lcdSerial(LCDRX,LCDTX); //software serial line.

void setup() {
  int errorcode = 0;
  pinMode(NEXT, INPUT); //select, next pins to input, enable internal pullup resistors.
  digitalWrite(NEXT, HIGH);
  pinMode(SELECT, INPUT);
  digitalWrite(SELECT, HIGH);

  digitalWrite(TARG_RESET, HIGH); //not reset.
  pinMode(TARG_RESET, OUTPUT);

  lcdSerial.begin(9600);  //connect to the LCD
  lcdSerial.print("?c0"); //turn off the cursor on the screen.
  lcdSerial.print(LCD_CLS);

  if (!card.init(SPI_HALF_SPEED)) {
    lcdSerial.println("Card init fail!"); //init card.
    while(1);
  }
  if (!volume.init(&card)) {
    lcdSerial.println("Volume init fail!");      //init FAT volume
  while(1);
  }
  if (!root.openRoot(&volume)) lcdSerial.println("Root init fail!");    //open the root directory of the volume.
  if(selectPinFile()<1) { //have the user select a file, and initialize it. 
    lcdSerial.print("File init fail!");
    while(1);
  }
  if(initTarget() != 0) {
    lcdSerial.print("device init fail!");  //initialize the target device.
    while(1); 
  }

  checkSig();

#if progressbar == 1 //finding the total number of program bytes in the file. Can be disabled to save space.
  while(parsePage() != 1);
  long int fileSize = numTotalBytes;  
  file.rewind(); 
  numTotalBytes = 0;

  if(initTarget() != 0) {
    lcdSerial.print("device init fail!");  //initialize the target device.
    while(1); 
  }
  #endif 
  lcdSerial.print(LCD_CLS); //clear screen
  lcdSerial.print("Programming");

  while(1) {
    //delay(10);
    if((errorcode = parsePage()) <0) { //parse a data page (not a page as in page 1, page 2.)
      lcdSerial.print("error parsing");
      lcdSerial.print(pageAddress);
      lcdSerial.print(numPageBytes);
      lcdSerial.print(errorcode);
      while(1);  
    }
    delay(10);

    if(programPage()<0) { //program the page we just parsed.
      lcdSerial.print("error programming!"); 
      while(1);
    }
#if verify == 1
    readPage(pageAddress, numPageBytes, (char *)tmp);
    for(int ii = 0; ii<pagesize; ii++) {
      if(data[ii] != tmp[ii]) {
        lcdSerial.print("Verify Error."); 
        lcdSerial.print(ii);
        while(1);
      }
    }
#endif
#if progressbar == 1 //printing out a progress bar, assumes 2x16 LCD. 
    lcdSerial.print(LOWERLEFT);
    for(int ii = 0; ii<map(numTotalBytes, 0, fileSize, 0, 16); ii++) {
      lcdSerial.print("*");
      delay(1);
    }
#endif

    if(errorcode ==1) { //errorcode = 1 then recordtype = 1, EOF.
      lcdSerial.print(LCD_CLS); //clear the screen
      lcdSerial.print("done!"); //tell the user we're done.
      Serial.write('Q');        //Adafruit no-wait mod to autostart the program.
      while(1); 
    }
  } 
}

void loop() {

}

//STK500 TARGET-SPEAK FUNCTIONS
void resetTarget() {
  digitalWrite(TARG_RESET, LOW); //pull the reset pin low.
  delay(250);
  digitalWrite(TARG_RESET, HIGH); //pull it back high.
  delay(100);
}

int initTarget () {
  Serial.begin(115200); //optiboot
  Serial.flush();
  resetTarget();
  for(int ii = 0; ii<5; ii++) { //try to establish contact.
    Serial.flush();
    Serial.write(STK_GET_SYNC);
    Serial.write(CRC_EOP);
    if(checkResponse() ==0) { //the device responded properly.
      lcdSerial.print(LCD_CLS);
      delay(5);
      lcdSerial.print("Optiboot"); //let the user know we have an optiboot device.
      delay(100);
      return 0;
    }
  } 
  Serial.end();
  Serial.begin(57600); //non-optiboot
  Serial.flush();
  resetTarget();
  for(int ii = 0; ii<5; ii++) { //establish contact.
    Serial.flush();
    Serial.write(STK_GET_SYNC);
    Serial.write(CRC_EOP);
    if(checkResponse() ==0) {
      lcdSerial.print(LCD_CLS); //contact established!
      lcdSerial.print("57600");
      delay(500);
      return 0;
    }
  } 


  Serial.end();
  Serial.begin(12900); //very old! 
  Serial.flush();
  resetTarget();
  for(int ii = 0; ii<5; ii++) { //establish contact.
    Serial.flush();
    Serial.write(STK_GET_SYNC);
    Serial.write(CRC_EOP);
    if(checkResponse() ==0) { //contact established!s
      lcdSerial.print(LCD_CLS);
      lcdSerial.print("12900");
      delay(100);
      return 0;
    }
  } 
  return -1; //nothing worked! umm.... maybe you didn't plug in the board? or plugged in wrong?

}



int programPage() { //STK500 program page.
  if(numPageBytes>0) {
    loadAddress(pageAddress);

    Serial.write(STK_PROG_PAGE); //let the bootloader know that data is coming.
    Serial.write((byte)0); //high byte of # ofbytes, always zero. amount of data <256 bytes.
    Serial.write((byte)numPageBytes); //low byte of# of bytes. 
    Serial.write("F"); //we are programming flash.
    Serial.write(data, numPageBytes); //write out all the bytes.

    Serial.write(CRC_EOP); // and we're done!
    return checkResponse();
  }
}

int checkResponse() { //checks that the bootloader returns STK_OK and 
  int resp1, resp2;
  unsigned long curtime = millis();
  while(!Serial.available()) {
    if(millis()-curtime>TIMEOUT) return -1;
  }
  // lcdSerial.print(LCD_CLS);
  //lcdSerial.print(Serial.read(), HEX);
  //lcdSerialr.print(Serial.read(), HEX);
  resp1=Serial.read();
  while(!Serial.available());
  resp2=Serial.read();
  //lcdSerial.print(resp1, HEX);
  //lcdSerial.print(resp2, HEX);
  if((resp1 != STK_INSYNC) && (resp2 != STK_OK))  return -1;
  //lcdSerial.print("init OK.");
  return 0;
}

int loadAddress(word address) {
  Serial.write(STK_LOAD_ADDRESS); //load page address into memory. This is the WORD address, which is byte address/2.
  Serial.write((byte)LOBYTE(address)); //low byte address
  Serial.write((byte)(HIBYTE(address))); //high byte address
  Serial.write(CRC_EOP); //next!
  if(checkResponse()<0) {
    lcdSerial.print("Address fail.");
    return -1;
  } 
  return 0;
}

int readPage(byte size, char *buffer) {
  int tmp;

  Serial.write(STK_READ_PAGE);
  Serial.write((byte)0);
  Serial.write((byte)size);
  Serial.write("F");
  Serial.write(CRC_EOP);

  while(!Serial.available());
  if(Serial.read() != STK_INSYNC) return -1; 
  int ii = 0;
  while(ii<size) {
    if(Serial.available()>0) {
      tmp = Serial.read();
      buffer[ii] = (byte)(tmp);
      //if((ii%16) == 0) lcdSerial.println();
      // lcdSerial.print(tmp, HEX);
      // lcdSerial.print(", ");
      ii++;
    }  
  delay(1);
  }
  if(Serial.read() != STK_OK) return -1; 
  return 0;
}

int readPage(word address, byte size, char *buffer) {
  loadAddress(address);
  return readPage(size, buffer);
}


int checkSig() { //check the device signature and sets the page size (in bytes);
  byte sig[3] = {
    0  }; //to store the signature when it gets sent.

  Serial.write(STK_READ_SIGN); //STK command
  Serial.write(CRC_EOP);
  while(!Serial.available());
  if(Serial.read() != STK_INSYNC) return -1;

  for(int ii = 0; ii<3;ii++) { 
    delay(5);
    sig[ii]=Serial.read(); 
  }

  if(Serial.read() != STK_OK) return -1;

  if((sig[0]==0x1E) && (sig[1]==0x94) && (sig[2]==0xB)) { 
    pagesize = 64*2;  
    return 0; 
  } //atmega168P  pagesize 64 words * (2 bytes/word) 
  if((sig[0]==0x1E) && (sig[1]==0x95) && (sig[2]==0xF)) { 
    pagesize = 64*2;  
    return 1; 
  }//atmega328P pagesize 64 words * (2 bytes/word)
  if((sig[0]==0x1E) && (sig[1]==0x97) && (sig[2]==0x3)) { 
    pagesize = 128*2; 
    return 2; 
  }//atmega1280 pagesize 128 words * (2 bytes/word)
  if((sig[0]==0x1E) && (sig[1]==0x98) && (sig[2]==0x1)) { 
    pagesize = 128*2; 
    return 3; 
  }//atmega2560 pagesize 128 words * (2 bytes/word)
}

//END STK-500 TARGET-SPEAK FUNCTIONS. 


// SD CARD READ, UI FUNCTIONS
char char2Hex(char c) {
  if (c>='0' && c<='9') return c-'0';
  if (c>='A' && c<='F') return c-'A'+10;
  if (c>='a' && c<='f') return c-'a'+10;
  return c=0;        // not Hex digit
}

int parsePage() {
  unsigned int checksum = 0; //for checksum summing.
  pageAddress = 0; //reset page address.
  byte numLineBytes = 0; //beauty of this is that we don't have to clear the data block every time.
  byte offset = 0; //to keep track of where we are in the buffer.
  word tmpAddress = 0; //to hold the byte address while we are going through. (for checksum summing.)
  recordType = 0; //normal 0, EOF 1.

  for(int ii = 0; ii<(pagesize/NUMDATABYTES); ii++) { //need to read x number of lines. generally 8 lines*16 bytes/line =128bytes.
    checksum = 0; //reset checksum calculator.
    if(file.read()!=':') { //each line should begin with :
      Serial.print("File begin error"); 
      return -1;
    }
    numLineBytes =NIB2BYTE(char2Hex((char)file.read()),char2Hex((char)file.read())); //read the byte that tells us the num of bytes
    tmpAddress = word(NIB2BYTE(char2Hex((char)file.read()),char2Hex((char)file.read())), NIB2BYTE(char2Hex((char)file.read()),char2Hex((char)file.read()))); 
    if(ii==0) pageAddress = tmpAddress; //for the first line read, its address is the byte address.
    recordType=NIB2BYTE(char2Hex((char)file.read()), char2Hex((char)file.read())); //read the record type byte.  
    if(recordType==1) goto EOFJMP; //EOF
    if((numLineBytes>0) && (((recordType)==0) || (recordType ==3))) { //there is actually data there

      for(int jj = offset; jj<(offset+numLineBytes); jj++) { 
        data[jj]=NIB2BYTE(char2Hex((char)file.read()), char2Hex((char)file.read())); //read all of the data bytes. absurd array location math needed to make some arbitrary point in string the "zeroth" data item.
        checksum += data[jj];//running checksum total.
      }
      offset=offset+numLineBytes;
    }
    checksum += numLineBytes+((tmpAddress & 255) +((tmpAddress>>8)& 255)) + recordType; //sum of data size byte, address bytes, record type, and all data bytes.
    checksum = TWOSCOMP(checksum); //generate the two's compliment (official checksum)
    if(checksum!=NIB2BYTE(char2Hex((char)file.read()), char2Hex((char)file.read()))) return -2; //if checksum doesn't check out, RUN!
    file.read();
    file.read();
  }
EOFJMP:
  numPageBytes = offset; //been summing the whole time.
  numTotalBytes += (numPageBytes); //for progress bar.
  pageAddress=pageAddress/2; //byte address to word address.
  if(recordType==1) return 1; //EOF
  return 0;
}

int selectPinFile() {
  char filename[13];
  int ii;
  dir_t dir;
  int stateSelect = HIGH;
  int stateNext = HIGH;
  int fileUpdated = 1;
  root.readDir(dir);

  while(1) {

    if((digitalRead(NEXT)==LOW) && (stateNext==HIGH)) {
nextFile:
      if (root.readDir(dir) != sizeof(dir)) {
        root.rewind();
        root.readDir(dir);
      }
      fileUpdated = 1;
    }
    if(fileUpdated>0) {
      SdFile::dirName(dir, filename);
      for(int ii = 0; ii<13; ii++) {
        if((filename[ii] == '.') && (filename[ii+1] == 'H') && (filename[ii+2] == 'E') && (filename[ii+3] == 'X')) { //if the file extension is ".hex"
          goto HexFile; //the file is hex.
        }
      }
      goto nextFile; //if the file isn't a hex file, get the next one. 
HexFile:
      lcdSerial.print(LCD_CLS);
      lcdSerial.print("File: ");
      lcdSerial.println(filename);
      fileUpdated=0;
    }
    if((digitalRead(SELECT)==LOW) && (stateSelect==HIGH)) {
      if(!(file.open(root, filename, O_READ))) return 0;
      goto fileselected;  
    }
    stateNext = digitalRead(NEXT);
    stateSelect = digitalRead(SELECT);
    delay(10);
  }
fileselected:
  file.rewind();
  return 1;
}

//END OF SD READ/UI FUNCTIONS







