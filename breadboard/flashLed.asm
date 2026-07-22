projet   segment
   assume   cs:projet, ds:projet, ss:projet

   org   7f0h
debut:   mov   al,10101010b

encore:  out   10h, al

   jmp   encore

projet   ends

end   debut
