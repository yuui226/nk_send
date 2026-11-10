import java.nio.file.*;
import java.util.*;
public class Order {
 static int compare(String a, String b) {
  for(int i=0;i<Math.min(a.length(),b.length());i++) {
   char x=a.charAt(i),y=b.charAt(i);
   if(x!=y) { x=Character.toUpperCase(x); y=Character.toUpperCase(y);
    if(x!=y) { x=Character.toLowerCase(x);y=Character.toLowerCase(y);if(x!=y)return x-y; }
   }
  }
  return a.length()-b.length();
 }
 public static void main(String[] args) throws Exception {
  List<String> names=Files.readAllLines(Path.of(args[0]));
  List<Integer> order=new ArrayList<>(); for(int i=0;i<names.size();i++)order.add(i);
  order.sort((a,b)->{int c=compare(names.get(a),names.get(b));return c!=0?c:names.get(a).compareTo(names.get(b));});
  System.out.println(order);
 }
}
